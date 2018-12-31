{-# LANGUAGE OverloadedStrings #-}

import           Control.Monad                   (mapM_)
import qualified Data.Attoparsec.ByteString.Lazy as A
import qualified Data.ByteString                 as B
import qualified Data.ByteString.Lazy            as L
import           Data.Word                       (Word8)
import           Numeric                         (showHex)
import           Test.QuickCheck
import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck           as QC

import           Network.MQTT.Types

prop_rtLength :: NonNegative (Large Int) -> Property
prop_rtLength (NonNegative (Large x)) =
  x <= 268435455 ==> label (show (length e) <> "B") $
  cover 20 (length e > 1) "multi-byte" $
  decodeLength e == x

  where e = encodeLength x

prop_rtLengthParser :: NonNegative (Large Int) -> Property
prop_rtLengthParser (NonNegative (Large x)) =
  x <= 268435455 ==> label (show (length e) <> "B") $
  cover 20 (length e > 1) "multi-byte" $
  d e == x

  where e = encodeLength x
        d :: [Word8] -> Int
        d l = case A.parse parseHdrLen (L.pack l) of
                (A.Fail _ _ _) -> undefined
                (A.Done _ v)   -> v

testControlPktType :: Assertion
testControlPktType = mapM_ tryParse [0..]
  where
    tryParse :: Word8 -> Assertion
    tryParse w = case A.parse parseControlPktType (L.singleton w) of
                   (A.Fail _ _ _) -> pure ()
                   (A.Done _ r) -> assertEqual ("Byte " <> showHex w "" <> " - " <> show r) [w] (toBytes r)

tests :: [TestTree]
tests = [
  localOption (QC.QuickCheckTests 10000) $ testProperty "header length rt" prop_rtLength,
  localOption (QC.QuickCheckTests 10000) $ testProperty "header length rt (parser)" prop_rtLengthParser,

  testCase "control pkt type" testControlPktType
  ]

main :: IO ()
main = defaultMain $ testGroup "All Tests" tests
