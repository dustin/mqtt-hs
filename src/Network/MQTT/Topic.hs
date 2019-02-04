{-|
Module      : Network.MQTT.Topic.
Description : An MQTT client.
Copyright   : (c) Dustin Sallings, 2019
License     : BSD3
Maintainer  : dustin@spy.net
Stability   : experimental

Topic and topic related utiilities.
-}

{-# LANGUAGE OverloadedStrings #-}

module Network.MQTT.Topic (
  Topic, match
) where

import           Data.Text (Text, splitOn, isPrefixOf)

-- | An MQTT topic.
type Topic = Text

-- | match returns true iff the given pattern can be matched by the
-- specified Topic as defined in the
-- <http://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html#_Toc398718107 MQTT 3.1.1 specification>.
match :: Text -> Topic -> Bool
match pat top = cmp (splitOn "/" pat) (splitOn "/" top)

  where
    cmp [] []   = True
    cmp [] _    = False
    cmp _ []    = False
    cmp ["#"] (t:_) = not $ "$" `isPrefixOf` t
    cmp (p:ps) (t:ts)
      | p == t = cmp ps ts
      | p == "+" && not ("$" `isPrefixOf` t) = cmp ps ts
      | otherwise = False
