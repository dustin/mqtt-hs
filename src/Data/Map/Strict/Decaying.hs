{-# LANGUAGE RecordWildCards #-}
module Data.Map.Strict.Decaying
  ( Map,
    new,
    insert,
    delete,
    elems,
    contained,
    findWithDefault,
    updateLookupWithKey,

    -- * Testing Hooks
    tick,
  )
where

import           Control.Concurrent.Async    (async, cancel, link)
import           Control.Concurrent.STM      (STM, atomically)
import           Control.Concurrent.STM.TVar (TVar, mkWeakTVar, modifyTVar', newTVarIO, readTVar, writeTVar)
import           Control.Exception           (mask)
import           Control.Monad               (forever, join, void, (<=<))
import           Control.Monad.Loops         (whileJust_)
import qualified Data.Map.Strict             as Map
import           Data.Maybe                  (mapMaybe)
import           Data.Time                   (NominalDiffTime)
import           Data.Time.Clock.POSIX       (POSIXTime, getPOSIXTime)
import           GHC.Conc                    (threadDelay)
import           System.Mem.Weak             (deRefWeak)

data Item a = Item {_itemTime :: {-# UNPACK #-} !POSIXTime, itemValue :: !a}

data Map k a = Map {
  mapVar  :: TVar (Map.Map k (Item a)),
  timeVar :: TVar POSIXTime,
  maxAge  :: NominalDiffTime
}

insert :: Ord k => k -> v -> Map k v -> STM ()
insert k v (Map m tv _) = do
  t <- readTVar tv
  modifyTVar' m (Map.insert k (Item t v))

delete :: Ord k => k -> Map k v -> STM ()
delete k (Map m _ _) = modifyTVar' m (Map.delete k)

findWithDefault :: Ord k => v -> k -> Map k v -> STM v
findWithDefault d k Map{..} = do
  now <- readTVar timeVar
  maybe d itemValue . (whenValid now maxAge <=< Map.lookup k) <$> readTVar mapVar

whenValid :: POSIXTime -> NominalDiffTime -> Item a -> Maybe (Item a)
whenValid now ma (Item t v) = if now < t + ma then Just (Item t v) else Nothing

-- | All visible records.
elems :: Map k a -> STM [a]
elems Map{..}= do
  now <- readTVar timeVar
  mapMaybe (fmap itemValue . whenValid now maxAge) . Map.elems <$> readTVar mapVar

-- | Overall number of records currently stored (including expired records)
contained :: Map k a -> STM Int
contained (Map m _ _) = Map.size <$> readTVar m

tick :: Map k v -> IO ()
tick Map{..} = getPOSIXTime >>= atomically . writeTVar timeVar

updateLookupWithKey ::
  Ord k => (k -> a -> Maybe a) -> k -> Map k a -> STM (Maybe a)
updateLookupWithKey f k (Map m tv _) = do
  t <- readTVar tv
  (mItem, m') <- Map.updateLookupWithKey (\k -> fmap (Item t) . f k . itemValue) k <$> readTVar m
  writeTVar m $! m'
  pure (itemValue <$> mItem)

new :: NominalDiffTime -> IO (Map k a)
new maxAge = mask $ \restore -> do
  var <- newTVarIO Map.empty
  tv <- newTVarIO =<< getPOSIXTime
  wVar <- mkWeakTVar var $ pure ()
  link <=< restore $ async $ whileJust_ (deRefWeak wVar) (reap tv)
  pure $ Map var tv maxAge
  where
    reap tv var = do
      now <- getPOSIXTime
      atomically $ do
        writeTVar tv now
        modifyTVar' var $ Map.filter $ \(Item t _) -> now - t < maxAge
      threadDelay $ max (truncate maxAge) 1
