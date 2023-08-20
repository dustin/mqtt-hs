module Data.Map.Strict.Decaying
  ( Map,
    new,
    insert,
    delete,
    elems,
    contained,
    findWithDefault,
    updateLookupWithKey,
  )
where

import           Control.Concurrent.Async    (async, cancel, link)
import           Control.Concurrent.STM      (STM, atomically)
import           Control.Concurrent.STM.TVar (TVar, mkWeakTVar, modifyTVar', newTVarIO, readTVar, writeTVar)
import           Control.Exception           (mask)
import           Control.Monad               (forever, void)
import qualified Data.Map.Strict             as Map
import           Data.Time                   (NominalDiffTime)
import           Data.Time.Clock.POSIX       (POSIXTime, getPOSIXTime)
import           GHC.Conc                    (threadDelay, unsafeIOToSTM)
import           System.Mem.Weak             (deRefWeak)

data Item a = Item {_itemTime :: {-# UNPACK #-} !POSIXTime, itemValue :: !a}

newtype Map k a = Map (TVar (Map.Map k (Item a)))

insert :: Ord k => k -> v -> Map k v -> STM ()
insert k v (Map m) = do
  t <- unsafeIOToSTM getPOSIXTime
  modifyTVar' m (Map.insert k (Item t v))

delete :: Ord k => k -> Map k v -> STM ()
delete k (Map m) = modifyTVar' m (Map.delete k)

findWithDefault :: Ord k => v -> k -> Map k v -> STM v
findWithDefault d k (Map m) = itemValue . Map.findWithDefault (Item 0 d) k <$> readTVar m

-- | All visible records.
elems :: Map k a -> STM [a]
elems (Map m) = fmap itemValue . Map.elems <$> readTVar m

-- | Overall number of records currently stored (including expired records)
contained :: Map k a -> STM Int
contained (Map m) = Map.size <$> readTVar m

updateLookupWithKey ::
  Ord k => (k -> a -> Maybe a) -> k -> Map k a -> STM (Maybe a)
updateLookupWithKey f k (Map m) = do
  t <- unsafeIOToSTM getPOSIXTime
  (mItem, m') <- Map.updateLookupWithKey (\k -> fmap (Item t) . f k . itemValue) k <$> readTVar m
  writeTVar m $! m'
  pure (itemValue <$> mItem)

new :: NominalDiffTime -> IO (Map k a)
new maxAge = mask $ \restore -> do
  var <- newTVarIO Map.empty
  wVar <- mkWeakTVar var $ pure ()
  reaper <- restore $ async $ reaperLoop wVar
  link reaper
  pure $ Map var
  where
    reaperLoop wVar = do
      mVar <- deRefWeak wVar
      case mVar of
        Just var -> do
          now <- getPOSIXTime
          atomically $ modifyTVar' var $ Map.filter $ \(Item t _) -> now - t < maxAge
          threadDelay $ truncate $ maxAge / 4
          reaperLoop wVar
        Nothing -> pure ()
