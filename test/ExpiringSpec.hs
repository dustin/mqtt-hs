{-# LANGUAGE BlockArguments             #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TupleSections              #-}


module ExpiringSpec where

import           Control.Lens
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

newtype GenOffset = GenOffset { getOffset :: Int }
  deriving (Eq, Ord)
  deriving newtype (Show, Num, Bounded)

instance Arbitrary GenOffset where
  arbitrary = GenOffset <$> choose (0, 5)
  shrink = fmap GenOffset . shrink . getOffset

data Mutation = Insert GenOffset SomeKey Int
              | Delete SomeKey
              | Update GenOffset SomeKey Int
              | UpdateNothing GenOffset SomeKey
              | NewGeneration GenOffset
  deriving Show

makePrisms ''Mutation

instance Arbitrary Mutation where
  arbitrary = oneof [Insert <$> arbitrary <*> arbitrary <*> arbitrary,
                     Delete <$> arbitrary,
                     Update <$> arbitrary <*> arbitrary <*> arbitrary,
                     UpdateNothing <$> arbitrary <*> arbitrary,
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
    massocs = degenerate $ foldl' applyOpM (0, mempty) ops
    eassocs = foldl' applyOpE (ExpiringMap.new 0) ops

    -- The emulation stores the generation along with the value, so when we're done, we filter out anything old and fmap away the generation.
    degenerate :: (GenOffset, Map.Map SomeKey (GenOffset, Int)) -> Map.Map SomeKey Int
    degenerate (gen, m) = snd <$> Map.filter ((>= gen) . fst) m

    applyOpM (gen, m) = \case
      Insert g k v      -> (gen, Map.insert k (gen+g, v) m)
      Delete k          -> (gen, Map.delete k m)
      Update g k v      -> (gen, snd $ Map.updateLookupWithKey (\_ _ -> Just (gen+g, v)) k m)
      UpdateNothing _ k -> (gen, snd $ Map.updateLookupWithKey (\_ _ -> Nothing) k m)
      NewGeneration n   -> (gen + n, Map.filter ((>= gen + n) . fst) m)

    applyOpE m = \case
      Insert g k v      -> ExpiringMap.insert (gen + g) k v m
      Delete k          -> ExpiringMap.delete k m
      Update g k v      -> snd $ ExpiringMap.updateLookupWithKey (gen + g) (\k' _ -> bool Nothing (Just v) (k == k')) k m
      UpdateNothing g k -> snd $ ExpiringMap.updateLookupWithKey (gen + g) (\_ _ -> Nothing) k m
      NewGeneration g   -> ExpiringMap.newGen (gen + g) m
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
