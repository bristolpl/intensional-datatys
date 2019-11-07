module ConGraph (
      ConGraph (ConGraph, succs, preds, subs)
    , empty
    , fromList
    , toList
    , closeScope
    , saturate
    , insert
    , union
    , substitute
    , graphMap
    -- , leastSolution
     ) where

import Control.Applicative hiding (empty)
import Control.Monad
import Control.Monad.RWS hiding (Sum)

import qualified Data.Map as M
import qualified Data.List as L
import Data.Bifunctor (second)

import qualified GhcPlugins as Core

import Types
import InferM

-- Constraint graph
data ConGraph = ConGraph {
  succs :: M.Map RVar [Type],
  preds :: M.Map RVar [Type],
  subs  :: M.Map RVar Type        -- Unique representations for cyclic equivalence classes
}

-- Empty constraint graph
empty :: ConGraph
empty = ConGraph { succs = M.empty, preds = M.empty, subs = M.empty }

-- Constructor a new constraint graph from a list
fromList :: [(Type, Type)] -> InferM ConGraph
fromList = foldM (\cg (t1, t2) -> insert t1 t2 cg) empty

-- Returns a list of constraints as internally represented
toList :: ConGraph -> [(Type, Type)]
toList ConGraph{succs = s, preds = p} = [(Var k, v) |(k, vs) <- M.toList s, v <- vs] ++ [(v, Var k) |(k, vs) <- M.toList p, v <- vs]

-- Early remove properly scoped bounded (intermediate) nodes that are not associated with the environment's stems (optimisation)
closeScope :: Int -> [Int] -> ConGraph -> ConGraph
closeScope scope envStems cg = foldr remove cg $ filter (\n -> all (\(n1, n2) -> notElem n [n1, n2] || (p n1 && p n2)) edges) $ filter p nodes
  where
    p (V x _ _ _) =  x > scope && (x `notElem` envStems)
    p _           = False 
    nodes = concat [[n1, n2] | (n1, n2) <- toList cg]
    edges = toList cg
    remove n ConGraph{succs = s, preds = p, subs = sb} = ConGraph{succs = mapRemove n s, preds = mapRemove n p, subs = sb}
    mapRemove n m = M.filterWithKey (\k _ -> Var k /= n) (filter (/= n) <$> m)

-- The fixed point of normalisation and transitivity
saturate :: ConGraph -> InferM [(Type, Type)]
saturate = saturate' . toList
  where
    saturate' cs = do
      delta <- concatMapM (\(a, b) -> concatMapM (\(b', c) -> if b == b' then toNorm a c else return []) cs) cs
      let cs' = L.nub (cs ++ delta)
      if cs == cs'
        then return cs
        else saturate' cs'

    concatMapM op = foldr f (return [])
      where
        f x xs = do x <- op x; if null x then xs else do xs <- xs; return $ x++xs

-- Apply function to set expressions without effecting variables
graphMap :: (Type -> Type) -> ConGraph -> ConGraph
graphMap f cg@ConGraph{succs = s, preds = p, subs = sb} =
  ConGraph {
    succs = fmap f <$> s,
    preds = fmap f <$> p,
    subs = f <$> sb
  }

-- Normalise the constraints by applying recursive simplifications (the last 2 rules)
toNorm :: Type -> Type -> InferM [(Type, Type)]
toNorm t1@(Con k as ts) t2@(V x p d as') = do
  args <- delta p d k as
  let ts' = upArrow x <$> args
  if ts' /= ts
    then do
      c1 <- toNorm (Con k as ts') (V x p d as')
      c2 <- toNorm (Con k as ts) (Con k as ts')
      return (c1 ++ c2)
    else return [(Con k as ts', V x p d as'), (Con k as ts, Con k as ts')]

toNorm t1@(V x p d as) t2@(Sum cs) = do
  let cons = Core.tyConDataCons d
  if all (\c -> c `elem` [c' | (c', _, []) <- cs]) cons
    then return [] -- Sum is total and so is a trivial constraint
    else do
      s <- mapM refineCon cs
      if cs /= s
        then do
          c1 <- toNorm (Sum s) (Sum cs)
          c2 <- toNorm (V x p d as) (Sum s)
          return (c1 ++ c2)
        else return [(Sum s, Sum cs),(V x p d as, Sum s)]
      where
        refineCon (k, as, ts) = do
          args <- delta p d k as
          return (k, as, upArrow x <$> args)

toNorm t1 t2 = return [(t1, t2)]

-- Insert new constraint with normalisation
insert :: Type -> Type -> ConGraph -> InferM ConGraph
insert t1 t2 cg = do
  cs <- toNorm t1 t2
  foldM (\cg (t1', t2') -> insertInner t1' t2' cg) cg cs

-- Insert new constraint
insertInner :: Type -> Type -> ConGraph -> InferM ConGraph
insertInner Dot _ cg = return cg
insertInner _ Dot cg = return cg -- Ignore any constriants concerning Dot

insertInner x y cg | x == y = return cg

insertInner (t1 :=> t2) (t1' :=> t2') cg = do
  cg' <- insert t1' t1 cg
  insert t2 t2' cg'

insertInner cx@(Con c as cargs) dy@(Con d as' dargs) cg
  | c == d && as == as'        = foldM (\cg (ci, di) -> insert ci di cg) cg $ zip cargs dargs
  | otherwise                  = Core.pprPanic "Constructor mismatch" (Core.ppr (cx, dy))


insertInner cx@(Con c as cargs) (Sum ((d, as', dargs):ds)) cg
  | c == d && as == as'        = foldM (\cg (ci, di) -> insert ci di cg) cg $ zip cargs dargs
  | otherwise                  = insert cx (Sum ds) cg

insertInner vx@(Var x) vy@(Var y) cg
  | x > y                      = insertSucc x vy cg
  | otherwise                  = insertPred vx y cg

insertInner (Var x) c@(Sum _) cg = insertSucc x c cg
insertInner c@Con{} (Var y) cg   = insertPred c y cg

insertInner (Sum cs) t cg = foldM (\cg (c, as, cargs) -> insert (Con c as cargs) t cg) cg cs

insertSucc :: RVar -> Type -> ConGraph -> InferM ConGraph
insertSucc x sy cg@ConGraph{succs = s, subs = sb} =
  case sb M.!? x of
    Just z    -> insert z sy cg
    _ ->
      case s M.!? x of
        Just ss ->
          if sy `elem` ss
            then return cg
            else do
              cg' <- closeSucc x sy cg{succs = M.insert x (sy:ss) s} 
              -- TODO: intersect sums
              case predChain cg' x sy [] of
                Just vs -> foldM (\cg x -> substitute x sy cg) cg' vs
                _ -> return cg'
        _ -> closeSucc x sy cg{succs = M.insert x [sy] s}

insertPred:: Type -> RVar -> ConGraph -> InferM ConGraph
insertPred sx y cg@ConGraph{preds = p, subs = sb} =
  case sb M.!? y of
    Just z    -> insert sx z cg
    _ ->
      case p M.!? y of
        Just ps ->
          if sx `elem` ps
            then return cg
            else do
              cg' <- closePred sx y cg{preds = M.insert y (sx:ps) p}
              -- TODO: union sums
              case succChain cg' sx y [] of
                Just vs -> foldM (\cg y -> substitute y sx cg) cg' vs
                _ -> return cg'
        _ -> closePred sx y cg{preds = M.insert y [sx] p}

-- Partial online transitive closure
closeSucc :: RVar -> Type -> ConGraph -> InferM ConGraph
closeSucc x sy cg =
  case preds cg M.!? x of
    Just ps   -> foldM (\cg p -> insert p sy cg) cg ps
    _ -> return cg

closePred :: Type -> RVar -> ConGraph -> InferM ConGraph
closePred sx y cg =
  case succs cg M.!? y of
    Just ss   -> foldM (flip $ insert sx) cg ss
    _ -> return cg

-- Partial online cycle elimination
predChain :: ConGraph -> RVar -> Type -> [RVar] -> Maybe [RVar]
predChain cg f (Var t) m = do
  guard $ f == t
  return $ f:m
predChain cg f t m = do
  ps <- preds cg M.!? f
  foldr (\t pl -> predLoop t <|> pl) Nothing ps
  where
    m' = f:m
    predLoop (Var p) = do
      guard $ p `elem` m' || p > f
      predChain cg p t m'
    predLoop t' = do
      guard $ t == t'
      return m'

succChain :: ConGraph -> Type -> RVar -> [RVar] -> Maybe [RVar]
succChain cg (Var f) t m = do
  guard $ f == t
  return $ t:m
succChain cg f t m = do
  ss <- succs cg M.!? t
  foldr (\f sl -> succLoop f <|> sl) Nothing ss
  where
    m' = t:m
    succLoop (Var s) = do
      guard $ s `elem` m' || t <= s
      succChain cg f s m'
    succLoop f' = do
      guard $ f == f'
      return m'

-- Union of constraint graphs
union :: ConGraph -> ConGraph -> InferM ConGraph
union cg1@ConGraph{subs = sb} cg2@ConGraph{succs = s, preds = p, subs = sb'} = do
  -- Combine equivalence classes using left representation
  let msb  = M.union sb (subVar <$> sb')

  -- Update cg1 with new equivalences
  cg1' <- M.foldrWithKey (\x se -> (>>= \cg -> substitute x se cg)) (return cg1) msb

  -- Insert edges from cg2 into cg1
  cg1'' <- M.foldrWithKey (\k vs -> (>>= \cg -> foldM (flip (insert (Var k))) cg vs)) (return cg1') s
  M.foldrWithKey (\k vs -> (>>= \cg -> foldM (\cg' v -> insert v (Var k) cg') cg vs)) (return cg1'') p
  where
    subVar (Var x) = M.findWithDefault (Var x) x sb
    subVar (Sum cs) = Sum (second (fmap subVar) <$> cs)

-- Safely substitute variable with an expression
substitute :: RVar -> Type -> ConGraph -> InferM ConGraph
substitute x se ConGraph{succs = s, preds = p, subs = sb} = do
  -- Necessary to recalculate preds and succs as se might not be a Var.
  -- If se is a Var this insures there are no redundant edges (i.e. x < x) or further simplifications.
  cg' <- case p' M.!? x of
    Just ps -> foldM (\cg pi -> insert pi se cg) cg ps
    Nothing -> return cg
  cg'' <- case s' M.!? x of
    Just ss -> foldM (flip $ insert se) cg' ss
    Nothing -> return cg'
  return cg''{ succs = M.delete x $ succs cg'', preds = M.delete x $ preds cg''}
  where
    sub (Var y) | x == y = se
    sub (Sum cs) = Sum $ fmap (second (fmap sub)) cs
    sub t = t
    p'  = fmap (L.nub . fmap sub) p
    s'  = fmap (L.nub . fmap sub) s
    cg = ConGraph { succs = s', preds = p', subs = M.insert x se $ fmap sub sb }
