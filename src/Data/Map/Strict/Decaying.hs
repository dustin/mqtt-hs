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
import           Control.Monad               (forever, void, (<=<))
import           Control.Monad.Loops         (whileJust_)
import qualified Data.Map.Strict             as Map
import           Data.Time                   (NominalDiffTime)
import           Data.Time.Clock.POSIX       (POSIXTime, getPOSIXTime)
import           GHC.Conc                    (threadDelay)
import           System.Mem.Weak             (deRefWeak)

data Item a = Item {_itemTime :: {-# UNPACK #-} !POSIXTime, itemValue :: !a}

data Map k a = Map (TVar (Map.Map k (Item a))) (TVar POSIXTime)

insert :: Ord k => k -> v -> Map k v -> STM ()
insert k v (Map m tv) = do
  t <- readTVar tv
  modifyTVar' m (Map.insert k (Item t v))

delete :: Ord k => k -> Map k v -> STM ()
delete k (Map m _) = modifyTVar' m (Map.delete k)

findWithDefault :: Ord k => v -> k -> Map k v -> STM v
findWithDefault d k (Map m _) = itemValue . Map.findWithDefault (Item 0 d) k <$> readTVar m

-- | All visible records.
elems :: Map k a -> STM [a]
elems (Map m _) = fmap itemValue . Map.elems <$> readTVar m

-- | Overall number of records currently stored (including expired records)
contained :: Map k a -> STM Int
contained (Map m _) = Map.size <$> readTVar m

updateLookupWithKey ::
  Ord k => (k -> a -> Maybe a) -> k -> Map k a -> STM (Maybe a)
updateLookupWithKey f k (Map m tv) = do
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
  pure $ Map var tv
  where
    reap tv var = do
      now <- getPOSIXTime
      atomically $ do
        writeTVar tv now
        modifyTVar' var $ Map.filter $ \(Item t _) -> now - t < maxAge
      threadDelay $ truncate $ maxAge / 4
