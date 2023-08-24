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
              | NewGeneration
  deriving Show

instance Arbitrary Mutation where
  arbitrary = oneof [Insert <$> arbitrary <*> arbitrary,
                     Delete <$> arbitrary,
                     Update <$> arbitrary <*> arbitrary,
                     UpdateNothing <$> arbitrary,
                     pure NewGeneration
                     ]

allOpTypes :: [String]
allOpTypes = ["Insert", "Delete", "Update", "UpdateNothing"]

-- Verify that after a series of operations, the map and expiring map return the same values for the given keys.
prop_expMapDoesMapStuff :: [Mutation] -> [SomeKey] -> Property
prop_expMapDoesMapStuff ops lookups =
  coverTable "pkt types" ((,5) <$> allOpTypes) $
  tabulate "pkt types" (takeWhile (/= ' ') . show <$> ops) $
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
      NewGeneration   -> const mempty

    applyOpE m = \case
      Insert k v      -> ExpiringMap.insert gen k v m
      Delete k        -> ExpiringMap.delete k m
      Update k v      -> snd $ ExpiringMap.updateLookupWithKey gen (\k' _ -> bool Nothing (Just v) (k == k')) k m
      UpdateNothing k -> snd $ ExpiringMap.updateLookupWithKey gen (\_ _ -> Nothing) k m
      NewGeneration   -> ExpiringMap.newGen (gen + 1) m
      where gen = ExpiringMap.generation m

prop_expiringMapWorks :: Int -> [Int] -> Property
prop_expiringMapWorks baseGen keys = Just keys === traverse (`ExpiringMap.lookup` m) keys
  where
    m = foldr (\x -> ExpiringMap.insert futureGen x x) (ExpiringMap.new baseGen) keys
    futureGen = succ baseGen

ulength :: (Ord a, Foldable t) => t a -> Int
ulength = Set.size . Set.fromList . toList

prop_expiringMapExpires :: Int -> [Int] -> Property
prop_expiringMapExpires baseGen keys = (ulength keys, futureGen, ulength keys) === ExpiringMap.inspect m1 .&&. (0, lastGen, 0) === ExpiringMap.inspect m2
  where
    m1 = ExpiringMap.newGen futureGen $ foldr (\x -> ExpiringMap.insert futureGen x x) (ExpiringMap.new baseGen) keys
    m2 = ExpiringMap.newGen lastGen m1
    futureGen = succ baseGen
    lastGen = succ futureGen

prop_expiringMapCannotAcceptExpired :: Positive Int -> Positive Int -> Int -> Property
prop_expiringMapCannotAcceptExpired (Positive lowGen) (Positive offset) k = ExpiringMap.inspect m === ExpiringMap.inspect m'
  where
    highGen = lowGen + offset
    m = ExpiringMap.new highGen :: ExpiringMap.Map Int Int Int
    m' = ExpiringMap.insert lowGen k k m

prop_expiringMapUpdateMissing :: Int -> Int -> Property
prop_expiringMapUpdateMissing gen k = mv === Nothing .&&. ExpiringMap.inspect m === ExpiringMap.inspect m'
  where
    m = ExpiringMap.new gen :: ExpiringMap.Map Int Int Bool
    (mv, m') = ExpiringMap.updateLookupWithKey gen (\_ _ -> Just True) k m

prop_expiringMapCannotUpdateExpired :: Positive Int -> Positive Int -> Int -> Property
prop_expiringMapCannotUpdateExpired (Positive lowGen) (Positive offset) k = mv === Nothing .&&. ExpiringMap.lookup k m' === Just True
  where
    highGen = lowGen + offset
    m = ExpiringMap.insert highGen k True $ ExpiringMap.new highGen
    (mv, m') = ExpiringMap.updateLookupWithKey lowGen (\_ _ -> Just False) k m

prop_expiringMapDelete :: Int -> [Int] -> Property
prop_expiringMapDelete baseGen keys = (ulength keys, baseGen, ulength keys) === ExpiringMap.inspect m .&&. (0, baseGen, 0) === ExpiringMap.inspect m'
  where
    m = foldr (\x -> ExpiringMap.insert futureGen x x) (ExpiringMap.new baseGen) keys
    m' = foldr ExpiringMap.delete m keys
    futureGen = succ baseGen

prop_expiringMapElems :: Int -> Set Int -> Property
prop_expiringMapElems baseGen keys = keys === Set.fromList (toList m)
  where
    m = foldr (\x -> ExpiringMap.insert futureGen x x) (ExpiringMap.new baseGen) keys
    futureGen = succ baseGen

prop_expiringMapGen :: Int -> Int -> Property
prop_expiringMapGen g1 g2 = ExpiringMap.inspect m === (0, max g1 g2, 0)
  where
    m :: ExpiringMap.Map Int Int Int
    m = ExpiringMap.newGen g2 $ ExpiringMap.new g1
