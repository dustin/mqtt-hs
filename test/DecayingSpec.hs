{-# LANGUAGE BlockArguments    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns      #-}

module DecayingSpec where

import           Control.Concurrent              (threadDelay)
import           Control.Concurrent.STM          (STM, atomically)
import           Control.Monad                   (foldM, mapM_)
import qualified Data.Attoparsec.ByteString.Lazy as A
import qualified Data.ByteString.Lazy            as L
import           Data.Foldable                   (traverse_)
import qualified Data.Map.Strict                 as Map
import qualified Data.Map.Strict.Decaying        as DecayingMap
import           Data.Set                        (Set)
import qualified Data.Set                        as Set

import           Test.QuickCheck

prop_decayingMapWorks :: [Int] -> Property
prop_decayingMapWorks keys = idempotentIOProperty $ do
  m <- DecayingMap.new 60
  atomically $ traverse_ (\x -> DecayingMap.insert x x m) keys
  found <- atomically $ traverse (\x -> DecayingMap.findWithDefault maxBound x m) keys
  pure $ found === keys

prop_decayingMapDecays :: [Int] -> Property
prop_decayingMapDecays keys = idempotentIOProperty $ do
  m <- DecayingMap.new 0.001
  atomically $ traverse_ (\x -> DecayingMap.insert x x m) keys
  threadDelay 5000
  DecayingMap.tick m
  found <- atomically $ DecayingMap.elems m
  pure $ found === []

prop_decayingMapUpdates :: Set Int -> Property
prop_decayingMapUpdates (Set.toList -> keys) = idempotentIOProperty $ do
  m <- DecayingMap.new 60
  atomically $ traverse_ (\x -> DecayingMap.insert x x m) keys
  updated <- atomically $ traverse (\x -> DecayingMap.updateLookupWithKey (\_ v -> Just (v + 1)) x m) keys
  found <- atomically $ traverse (\x -> DecayingMap.findWithDefault maxBound x m) keys
  pure $ (found === fmap (+ 1) keys .&&. Just found === sequenceA updated)

prop_decayingMapDeletes :: Set Int -> Property
prop_decayingMapDeletes (Set.toList -> keys) = (not . null) keys ==> idempotentIOProperty $ do
  m <- DecayingMap.new 60
  atomically $ traverse_ (\x -> DecayingMap.insert x x m) keys
  atomically $ traverse (`DecayingMap.delete` m) (tail keys)
  found <- atomically $ DecayingMap.elems m
  pure $ found === take 1 keys
