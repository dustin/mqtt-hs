{-# LANGUAGE DeriveFunctor   #-}
{-# LANGUAGE RecordWildCards #-}
module Data.Map.Strict.Expiring (
    Map,
    new,
    generation,
    newGen,

    insert,
    delete,
    lookup,
    updateLookupWithKey,
    assocs,

    -- * for testing
    inspect
) where

import           Data.Foldable   (fold)
import qualified Data.Map.Strict as Map
import           Data.Maybe      (fromMaybe, mapMaybe)
import           Data.Set        (Set)
import qualified Data.Set        as Set
import           Prelude         hiding (lookup, map)

data Entry g a = Entry {
  value :: !a,
  gen   :: !g
} deriving (Functor, Show)

data Map g k a = Map {
  map        :: !(Map.Map k (Entry g a)),
  generation :: !g,
  aging      ::  !(Map.Map g (Set k))
} deriving (Functor, Show)

instance Ord g => Foldable (Map g k) where
    foldMap f = foldMap (f . value) . Map.elems . map

instance (Ord a, Ord g, Ord k) => Semigroup (Map g k a) where
    Map m1 g1 a1 <> Map m2 g2 a2 = Map (m1 <> m2) (max g1 g2) (a1 <> a2)

-- | Make a new empty Map at the starting generation.
new :: g -> Map g k a
new g = Map Map.empty g Map.empty

-- | 𝑂(log𝑛). Assign the next generation and expire any data this new generation invalidates.
-- The generation may never decrease.  Attempts to decrease it are ignored.
newGen :: (Ord k, Ord g) => g -> Map g k a -> Map g k a
newGen g m
    | g > generation m = expire m { generation = g }
    | otherwise = m

-- | 𝑂(log𝑛). Insert a new value into the map to expire after the given generation.
insert :: (Ord k, Ord g) => g -> k -> a -> Map g k a -> Map g k a
insert g _ _ m | g < generation m = m
insert g k v m@Map{..} = m {
  map = Map.insert k (Entry v g) map,
  aging = Map.insertWith (<>) g (Set.singleton k) aging
}

-- 𝑂(log𝑛). Lookup and update.
-- The function returns changed value, if it is updated. Returns the original key value if the map entry is deleted.
updateLookupWithKey :: (Ord g, Ord k) => g -> (k -> a -> Maybe a) -> k -> Map g k a -> (Maybe a, Map g k a)
updateLookupWithKey g _ _ m | g < generation m = (Nothing, m)
updateLookupWithKey g f k m@Map{..} = case Map.updateLookupWithKey f' k map of
  (Nothing, _) -> (Nothing, m)
  (Just e, m') -> (Just (value e), m {
    map = m',
    aging = Map.insert g (Set.singleton k) (removeAging (gen e) k aging)
  })
  where
    f' _ e = case f k (value e) of
      Just a  -> Just (Entry a g)
      Nothing -> Nothing

removeAging :: (Ord g, Ord k) => g -> k -> Map.Map g (Set k) -> Map.Map g (Set k)
removeAging g k = Map.update (nonNull . Set.delete k) g
    where nonNull s = if Set.null s then Nothing else Just s

-- | 𝑂(log𝑛). Lookup a value in the map.
-- This will not return any items that have expired.
lookup :: (Ord k, Ord g) => k -> Map g k a -> Maybe a
lookup k Map{..} = value <$> Map.lookup k map

-- | 𝑂(log𝑛). Delete an item.
delete :: (Ord k, Ord g) => k -> Map g k a -> Map g k a
delete k m@Map{..} = case Map.lookup k map of
  Nothing -> m
  Just Entry{..} -> m {
    map = Map.delete k map,
    aging = removeAging gen k aging
  }

-- | 𝑂(𝑛). Return all current key/value associations.
assocs :: Ord g => Map g k a -> [(k,a)]
assocs Map{..} = fmap value <$> Map.assocs map

-- | 𝑂(log𝑛).  Expire older generation items.
expire :: (Ord g, Ord k) => Map g k a -> Map g k a
expire m@Map{..} = m{ map = map', aging = aging'}
    where
        (kill, mm, agingG) = Map.splitLookup generation aging
        aging' = agingG <> maybe mempty (Map.singleton generation) mm
        todo = fold kill
        map' = foldr mightDelete map todo
        mightDelete k m = case whenValid generation =<< Map.lookup k m of
                            Nothing -> Map.delete k m
                            Just _  -> m

        whenValid g e@(Entry a t)
            | g < t = Just e
            | otherwise = Nothing


-- | Inspect stored size for testing.
inspect :: Ord k => Map g k a -> (Int, g, Int)
inspect Map{..} = (Map.size map, generation, length $ fold aging)
