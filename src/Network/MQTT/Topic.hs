{-|
Module      : Network.MQTT.Topic.
Description : MQTT Topic types and utilities.
Copyright   : (c) Dustin Sallings, 2019
License     : BSD3
Maintainer  : dustin@spy.net
Stability   : experimental

Topic and topic related utiilities.
-}

{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}

module Network.MQTT.Topic (
  Filter, unFilter, Topic, unTopic, match,
  mkFilter, mkTopic, split, toFilter
) where

import           Data.String (IsString (..))
import           Data.Text   (Text, isPrefixOf, splitOn)

class Splittable a where
  -- | split separates a `Filter` or `Topic` into its `/`-separated components.
  split :: a -> [a]

-- | An MQTT topic.
newtype Topic = Topic { unTopic :: Text } deriving (Show, Ord, Eq, IsString)

instance Splittable Topic where
  split (Topic t) = Topic <$> splitOn "/" t

instance Semigroup Topic where
  (Topic a) <> (Topic b) = Topic (a <> "/" <> b)

-- | mkTopic creates a topic from a text representation of a valid filter.
mkTopic :: Text -> Maybe Topic
mkTopic "" = Nothing
mkTopic t = Topic <$> validate (splitOn "/" t)
  where
    validate ("#":_) = Nothing
    validate ("+":_) = Nothing
    validate []      = Just t
    validate (_:xs)  = validate xs

-- | An MQTT topic filter.
newtype Filter = Filter { unFilter :: Text } deriving (Show, Ord, Eq, IsString)

instance Splittable Filter where
  split (Filter f) = Filter <$> splitOn "/" f

instance Semigroup Filter where
  (Filter a) <> (Filter b) = Filter (a <> "/" <> b)

-- | mkFilter creates a filter from a text representation of a valid filter.
mkFilter :: Text -> Maybe Filter
mkFilter "" = Nothing
mkFilter t = Filter <$> validate (splitOn "/" t)
  where
    validate ["#"]   = Just t
    validate ("#":_) = Nothing
    validate []      = Just t
    validate (_:xs)  = validate xs

-- | match returns true iff the given pattern can be matched by the
-- specified Topic as defined in the
-- <http://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html#_Toc398718107 MQTT 3.1.1 specification>.
--
-- A wildcard at the start of a filter doesn't match a topic beginning
-- with @$@, but wildcards further in match @$@ levels like any other
-- [MQTT-4.7.2-1].
match :: Filter -> Topic -> Bool
match (Filter pat) (Topic top) = case (splitOn "/" pat, splitOn "/" top) of
  (p:_, t:_) | p `elem` ["#", "+"] && "$" `isPrefixOf` t -> False
  (ps, ts) -> cmp ps ts

  where
    cmp [] []       = True
    cmp [] _        = False
    cmp ["#"] _     = True
    cmp _ []        = False
    cmp (p:ps) (t:ts)
      | p == t || p == "+" = cmp ps ts
      | otherwise = False

-- | Convert a 'Topic' to a 'Filter' as all 'Topic's are valid 'Filter's
toFilter :: Topic -> Filter
toFilter = Filter . unTopic
