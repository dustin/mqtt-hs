{-# LANGUAGE BlockArguments    #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}

module ExpiringSpec where

import           Data.Bool                (bool)
import           Data.Foldable            (foldl', toList, traverse_)
import           Data.Function            ((&))
import qualified Data.Map.Strict          as Map
import qualified Data.Map.Strict.Expiring as ExpiringMap
import           Data.Set                 (Set)
import qualified Data.Set                 as Set

import           Test.QuickCheck

data SomeKey = Key1 | Key2 | Key3 | Key4 | Key5
  deriving (Bounded, Enum, Eq, Ord, Show)

instance Arbitrary SomeKey where
  arbitrary = arbitraryBoundedEnum

data Mutation = Insert SomeKey Int
              | Delete SomeKey
              | Update SomeKey Int
              | UpdateNothing SomeKey
              | NewGeneration (Positive Int)
  deriving Show

instance Arbitrary Mutation where
  arbitrary = oneof [Insert <$> arbitrary <*> arbitrary,
                     Delete <$> arbitrary,
                     Update <$> arbitrary <*> arbitrary,
                     UpdateNothing <$> arbitrary,
                     NewGeneration <$> arbitrary
                     ]

allOpTypes :: [String]
allOpTypes = ["Insert", "Delete", "Update", "UpdateNothing", "NewGeneration"]

-- Verify that after a series of operations, the map and expiring map return the same values for the given keys.
prop_doesMapStuff :: [Mutation] -> [SomeKey] -> Property
prop_doesMapStuff ops lookups =
  coverTable "mutation types" ((,5) <$> allOpTypes) $ -- The test paths should hit every mutation type (5% min)
  tabulate "mutation types" (takeWhile (/= ' ') . show <$> ops) $ -- We can identify one by the first word in its constructor
  checkCoverage $
  ((`Map.lookup` massocs) <$> lookups) === ((`ExpiringMap.lookup` eassocs) <$> lookups)
  where
    massocs = foldl' (flip applyOpM) (mempty :: Map.Map SomeKey Int) ops
    eassocs = foldl' applyOpE (ExpiringMap.new 0) ops

    applyOpM = \case
      Insert k v      -> Map.insert k v
      Delete k        -> Map.delete k
      Update k v      -> snd . Map.updateLookupWithKey (\_ _ -> Just v) k
      UpdateNothing k -> snd . Map.updateLookupWithKey (\_ _ -> Nothing) k
      NewGeneration _ -> const mempty

    applyOpE m = \case
      Insert k v      -> ExpiringMap.insert gen k v m
      Delete k        -> ExpiringMap.delete k m
      Update k v      -> snd $ ExpiringMap.updateLookupWithKey gen (\k' _ -> bool Nothing (Just v) (k == k')) k m
      UpdateNothing k -> snd $ ExpiringMap.updateLookupWithKey gen (\_ _ -> Nothing) k m
      NewGeneration n -> ExpiringMap.newGen (gen + getPositive n) m
      where gen = ExpiringMap.generation m

prop_updateReturn :: Int -> Property
prop_updateReturn x = (Just plus2, Just plus2, Nothing, Just plus2) === (up1, ExpiringMap.lookup x m', up2, up3)
    where
        m = ExpiringMap.insert 0 x 0 $ ExpiringMap.new 0
        plus2 = x + 2
        (up1, m') = ExpiringMap.updateLookupWithKey 0 (\_ v -> Just (x + 2)) x m -- New value returns new value
        (up2, m'') = ExpiringMap.updateLookupWithKey 0 (\_ v -> Just (x + 3)) (x + 1) m' -- Missing returns nothing
        up3 = fst $ ExpiringMap.updateLookupWithKey 0 (\_ v -> Nothing) x m'' -- Nothing returns previous value

prop_cannotAcceptExpired :: Positive Int -> Positive Int -> Int -> Property
prop_cannotAcceptExpired (Positive lowGen) (Positive offset) k = ExpiringMap.inspect m === ExpiringMap.inspect m'
  where
    highGen = lowGen + offset
    m = ExpiringMap.new highGen :: ExpiringMap.Map Int Int Int
    m' = ExpiringMap.insert lowGen k k m

prop_cannotUpdateExpired :: Positive Int -> Positive Int -> Int -> Property
prop_cannotUpdateExpired (Positive lowGen) (Positive offset) k = mv === Nothing .&&. ExpiringMap.lookup k m' === Just True
  where
    highGen = lowGen + offset
    m = ExpiringMap.insert highGen k True $ ExpiringMap.new highGen
    (mv, m') = ExpiringMap.updateLookupWithKey lowGen (\_ _ -> Just False) k m

prop_assocs :: [SomeKey] -> Property
prop_assocs keys = ExpiringMap.assocs m === Map.assocs (Map.fromList $ zip keys keys)
  where
    m = foldr (\k -> ExpiringMap.insert 0 k k) (ExpiringMap.new 0) keys

prop_generation :: Int -> Int -> Property
prop_generation g1 g2 = ExpiringMap.inspect m === (0, max g1 g2, 0)
  where
    m :: ExpiringMap.Map Int Int Int
    m = ExpiringMap.newGen g2 $ ExpiringMap.new g1
