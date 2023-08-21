{-# LANGUAGE RecordWildCards #-}
module Data.Map.Strict.Decaying
  ( Map,
    new,
    insert,
    delete,
    elems,
    findWithDefault,
    updateLookupWithKey,

    -- * Testing Hooks
    tick,
  )
where

import           Control.Concurrent.Async    (async, cancel, link)
import           Control.Concurrent.STM      (STM, atomically)
import           Control.Concurrent.STM.TVar (TVar, mkWeakTVar, modifyTVar', newTVarIO, readTVar, stateTVar, writeTVar)
import           Control.Exception           (mask)
import           Control.Monad               (forever, join, void, (<=<))
import           Control.Monad.Loops         (whileJust_)
import           Data.Foldable               (toList)
import qualified Data.Map.Strict.Expiring    as Map
import           Data.Maybe                  (fromMaybe, mapMaybe)
import           Data.Time                   (NominalDiffTime)
import           Data.Time.Clock.POSIX       (POSIXTime, getPOSIXTime)
import           GHC.Conc                    (threadDelay)
import           System.Mem.Weak             (deRefWeak)

data Map k a = Map {
  mapVar :: TVar (Map.Map POSIXTime k a),
  maxAge :: NominalDiffTime
}

expiry :: NominalDiffTime -> Map.Map POSIXTime k a -> POSIXTime
expiry ma = (+ ma) . Map.generation

insert :: Ord k => k -> v -> Map k v -> STM ()
insert k v (Map m ma) = modifyTVar' m (\m -> Map.insert (expiry ma m) k v m)

delete :: Ord k => k -> Map k v -> STM ()
delete k (Map m _) = modifyTVar' m (Map.delete k)

findWithDefault :: Ord k => v -> k -> Map k v -> STM v
findWithDefault d k Map{..} = fromMaybe d . Map.lookup k <$> readTVar mapVar

-- | All visible records.
elems :: Map k a -> STM [a]
elems Map{..} = toList <$> readTVar mapVar

tick :: Ord k => Map k v -> IO ()
tick Map{..} = getPOSIXTime >>= \t -> atomically $ modifyTVar' mapVar (Map.newGen t)

updateLookupWithKey :: Ord k => (k -> a -> Maybe a) -> k -> Map k a -> STM (Maybe a)
updateLookupWithKey f k (Map mv ma) = stateTVar mv (\m -> Map.updateLookupWithKey (expiry ma m) f k m)

new :: Ord k => NominalDiffTime -> IO (Map k a)
new maxAge = mask $ \restore -> do
  now <- getPOSIXTime
  var <- newTVarIO (Map.new now)
  wVar <- mkWeakTVar var $ pure ()
  let m = Map var maxAge
  link <=< restore $ async $ whileJust_ (deRefWeak wVar) (\m' -> tick' m' *> threadDelay 1000000)
  pure m
  where
    tick' m = getPOSIXTime >>= \t -> atomically $ modifyTVar' m (Map.newGen t)
