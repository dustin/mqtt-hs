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
match :: Filter -> Topic -> Bool
match (Filter pat) (Topic top) = cmp (splitOn "/" pat) (splitOn "/" top)

  where
    cmp [] []       = True
    cmp [] _        = False
    cmp ["#"] []    = True
    cmp _ []        = False
    cmp ["#"] (t:_) = not $ "$" `isPrefixOf` t
    cmp (p:ps) (t:ts)
      | p == t = cmp ps ts
      | p == "+" && not ("$" `isPrefixOf` t) = cmp ps ts
      | otherwise = False

-- | Convert a 'Topic' to a 'Filter' as all 'Topic's are valid 'Filter's
toFilter :: Topic -> Filter
toFilter = Filter . unTopic
