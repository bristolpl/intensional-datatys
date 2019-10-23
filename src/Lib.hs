module Lib
    ( plugin
    ) where

import Data.List
import qualified Data.Map as M hiding (partition, filter, drop, foldr)
import InferCoreExpr
import GhcPlugins
import InferM
import Utils
import Types
import Control.Monad.RWS hiding (Sum, Alt)
import Control.Monad.Except
import Debug.Trace
import TyCoRep

plugin :: Plugin
plugin = defaultPlugin { installCoreToDos = install }
  where
    install _ todo = return ([ CoreDoPluginPass "Constraint Inference" (liftIO. inferGuts)] ++ todo)

inferGuts :: ModGuts -> IO ModGuts
inferGuts guts@ModGuts{mg_binds = bs, mg_tcs = tcs}= do
    let env = Context{con = M.fromList (foldr buildContext [] tcs), var = M.empty}
    let p = filter (all isOfMain . bindersOf) bs
    case runExcept $ runRWST (listen $ inferProg p) env 0 of
      Left err -> putStrLn "Inference error: " >> print err >> return guts
      Right ((m, _), _, _) -> putStrLn "Success" >> print (show m) >> return guts
    return guts
  where
    isOfMain b = isPrefixOf "$main$Test$" (name b) && not (isPrefixOf "$main$Test$$" (name b))

buildContext :: TyCon -> [(String, (TyCon, [Sort]))] -> [(String, (TyCon, [Sort]))]
buildContext t xs = xs' ++ xs
  where
    xs' = foldr go [] (tyConDataCons t)

    go :: DataCon -> [(String, (TyCon, [Sort]))] -> [(String, (TyCon, [Sort]))]
    go d ys = (name d, (t, sorts)):ys
      where
        sorts = fmap toSort $ dataConOrigArgTys d