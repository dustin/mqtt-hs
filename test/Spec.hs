{-# LANGUAGE BlockArguments    #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications  #-}
{-# LANGUAGE ViewPatterns      #-}

import           Control.Concurrent              (threadDelay)
import           Control.Concurrent.STM          (STM, atomically)
import           Control.Monad                   (foldM, mapM_)
import           Control.Monad.RWS.Strict
import qualified Data.Attoparsec.ByteString.Lazy as A
import qualified Data.ByteString.Lazy            as L
import           Data.ByteString.Lazy.Char8      (foldl')
import           Data.Foldable                   (toList, traverse_)
import           Data.Functor.Identity           (Identity)
import qualified Data.Map.Strict                 as Map
import qualified Data.Map.Strict.Decaying        as DecayingMap
import qualified Data.Map.Strict.Expiring        as ExpiringMap
import           Data.Set                        (Set)
import qualified Data.Set                        as Set
import           Data.String                     (fromString)
import qualified Data.Text                       as T
import           Data.Word                       (Word8)
import           Network.MQTT.Arbitrary
import           Network.MQTT.Topic
import           Network.MQTT.Types              as MT

import           Test.QuickCheck                 as QC
import           Test.QuickCheck.Checkers
import           Test.QuickCheck.Classes
import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck           as QC

prop_rtLengthParser :: SizeT -> QC.Property
prop_rtLengthParser (SizeT x) =
  label (show (length e) <> "B") $
  d e == x

  where e = encodeLength x
        d :: [Word8] -> Int
        d l = case A.parse parseHdrLen (L.pack l) of
                A.Fail{}     -> undefined
                (A.Done _ v) -> v

testPacketRT :: Assertion
testPacketRT = mapM_ tryParse [
  "\DLE0\NUL\EOTMQTT\EOT\198\SOH,\NUL\ACKsomeid\NUL\btmp/test\NUL\STXhi\NUL\ACKdustin\NUL\ACKpasswd",
  " \STX\SOH\NUL"
  ]

  where
    tryParse s = do
      let (A.Done _ x) = A.parse (parsePacket Protocol311) s
      case A.parse (parsePacket Protocol311) (toByteString Protocol311 x) of
        f@A.Fail{}    -> assertFailure (show f)
        (A.Done _ x') -> assertEqual (show s) x x'

prop_PacketRT50 :: MQTTPkt -> QC.Property
prop_PacketRT50 p = label (lab p) $ case A.parse (parsePacket Protocol50) (toByteString Protocol50 p) of
                                         A.Fail{}     -> False
                                         (A.Done _ r) -> r == p

  where lab x = let (s,_) = break (== ' ') . show $ x in s

prop_PacketRT311 :: MQTTPkt -> QC.Property
prop_PacketRT311 p = available p ==>
  let p' = v311mask p in
    label (lab p') $ case A.parse (parsePacket Protocol311) (toByteString Protocol311 p') of
                      A.Fail{}     -> False
                      (A.Done _ r) -> r == p'

  where
    lab x = let (s,_) = break (== ' ') . show $ x in s

    available (AuthPkt _) = False
    available _           = True

prop_PropertyRT :: MT.Property -> QC.Property
prop_PropertyRT p = label (lab p) $ case A.parse parseProperty (toByteString Protocol50 p) of
                                    A.Fail{}     -> False
                                    (A.Done _ r) -> r == p

  where lab x = let (s,_) = break (== ' ') . show $ x in s

prop_SubOptionsRT :: SubOptions -> Bool
prop_SubOptionsRT o = case A.parse parseSubOptions (toByteString Protocol50 o) of
                      A.Fail{}     -> False
                      (A.Done _ r) -> r == o

prop_PropertiesRT :: [MT.Property] -> Bool
prop_PropertiesRT p = case A.parse (parseProperties Protocol50) (bsProps Protocol50 p) of
                        A.Fail{}     -> False
                        (A.Done _ r) -> r == p

testTopicMatching :: [TestTree]
testTopicMatching = let allTopics = ["a", "a/b", "a/b/c/d", "b/a/c/d",
                                     "$SYS/a/b", "a/$SYS/b"]
                        tsts = [("a", ["a"]), ("a/#", ["a", "a/b", "a/b/c/d"]),
                                ("+/b", ["a/b"]),
                                ("+/+/c/+", ["a/b/c/d", "b/a/c/d"]),
                                ("+/+/b", []),
                                ("+/$SYS/b", ["a/$SYS/b"]),
                                ("$SYS/#", ["$SYS/a/b"]),
                                ("+/$SYS/+", ["a/$SYS/b"]),
                                ("#/b", [])] in
    map (\(p,want) -> testCase (show p) $ assertEqual "" want (filter (match p) allTopics)) tsts

prop_TopicMatching :: MatchingTopic -> QC.Property
prop_TopicMatching (MatchingTopic (t,ms)) = counterexample (show ms <> " doesn't match " <> show t) $
  all (\m -> match m t) ms

byteRT :: (ByteSize a, Show a, Eq a) => a -> Bool
byteRT x = x == (fromByte . toByte) x

testQoSFromInt :: Assertion
testQoSFromInt = do
  mapM_ (\q -> assertEqual (show q) (Just q) (qosFromInt (fromEnum q))) [QoS0 ..]
  assertEqual "invalid QoS" Nothing (qosFromInt 1939)

instance EqProp Filter where (=-=) = eq
instance EqProp Topic where (=-=) = eq

prop_decayingMapWorks :: [Int] -> QC.Property
prop_decayingMapWorks keys = idempotentIOProperty $ do
  m <- DecayingMap.new 60
  atomically $ traverse_ (\x -> DecayingMap.insert x x m) keys
  found <- atomically $ traverse (\x -> DecayingMap.findWithDefault maxBound x m) keys
  pure $ found === keys

prop_decayingMapDecays :: [Int] -> QC.Property
prop_decayingMapDecays keys = idempotentIOProperty $ do
  m <- DecayingMap.new 0.001
  atomically $ traverse_ (\x -> DecayingMap.insert x x m) keys
  threadDelay 5000
  DecayingMap.tick m
  found <- atomically $ DecayingMap.elems m
  pure $ found === []

prop_decayingMapUpdates :: Set Int -> QC.Property
prop_decayingMapUpdates (Set.toList -> keys) = idempotentIOProperty $ do
  m <- DecayingMap.new 60
  atomically $ traverse_ (\x -> DecayingMap.insert x x m) keys
  updated <- atomically $ traverse (\x -> DecayingMap.updateLookupWithKey (\_ v -> Just (v + 1)) x m) keys
  found <- atomically $ traverse (\x -> DecayingMap.findWithDefault maxBound x m) keys
  pure $ (found === fmap (+ 1) keys .&&. Just found === sequenceA updated)

prop_decayingMapDeletes :: Set Int -> QC.Property
prop_decayingMapDeletes (Set.toList -> keys) = (not . null) keys ==> idempotentIOProperty $ do
  m <- DecayingMap.new 60
  atomically $ traverse_ (\x -> DecayingMap.insert x x m) keys
  atomically $ traverse (\x -> DecayingMap.delete x m) (tail keys)
  found <- atomically $ DecayingMap.elems m
  pure $ found === take 1 keys

testDecayingMap :: [TestTree]
testDecayingMap = [
  testProperty "works" prop_decayingMapWorks,
  testProperty "decaying map decays" prop_decayingMapDecays,
  testProperty "updates" prop_decayingMapUpdates,
  testProperty "deletes" prop_decayingMapDeletes
  ]

newtype SomeKey = SomeKey Char
  deriving (Eq, Ord, Show)

instance Arbitrary SomeKey where
  arbitrary = SomeKey <$> elements ['a'..'e']

data MapOp = MapInsert SomeKey Int
           | MapDelete SomeKey
           | MapLookup SomeKey
           | MapUpdate SomeKey Int
           | MapUpdateNothing SomeKey
  deriving Show

instance Arbitrary MapOp where
  arbitrary = oneof [MapInsert <$> arbitrary <*> arbitrary,
                     MapDelete <$> arbitrary,
                     MapLookup <$> arbitrary,
                     MapUpdate <$> arbitrary <*> arbitrary,
                     MapUpdateNothing <$> arbitrary
                     ]

prop_expMapDoesMapStuff :: [MapOp] -> QC.Property
prop_expMapDoesMapStuff ops = massocs === eassocs
  where
    massocs = snd $ evalRWS (applyOpsM ops) () (mempty :: Map.Map SomeKey Int)
    eassocs = snd $ evalRWS (applyOpsE ops) () (ExpiringMap.new 0)

    applyOpsM = traverse_ \case
      MapInsert k v -> do
        modify $ Map.insert k v
        tell =<< gets Map.assocs
      MapDelete k -> do
        modify $ Map.delete k
        tell =<< gets Map.assocs
      MapLookup k -> do
        gets (Map.lookup k) >>= \case
          Nothing -> pure ()
          Just v  -> tell [(k, v)]
      MapUpdate k v -> do
        modify $ fmap snd $ Map.updateLookupWithKey (\_ _ -> Just v) k
        tell =<< gets Map.assocs
      MapUpdateNothing k -> do
        modify $ fmap snd $ Map.updateLookupWithKey (\_ _ -> Nothing) k
        tell =<< gets Map.assocs

    applyOpsE = traverse_ \case
      MapInsert k v -> do
        modify $ ExpiringMap.insert 1 k v
        tell =<< gets ExpiringMap.assocs
      MapDelete k -> do
        modify $ ExpiringMap.delete k
        tell =<< gets ExpiringMap.assocs
      MapLookup k -> do
        gets (ExpiringMap.lookup k) >>= \case
          Nothing -> pure ()
          Just v  -> tell [(k, v)]
      MapUpdate k v -> do
        modify $ fmap snd $ ExpiringMap.updateLookupWithKey 1 (\_ _ -> Just v) k
        tell =<< gets ExpiringMap.assocs
      MapUpdateNothing k -> do
        modify $ fmap snd $ ExpiringMap.updateLookupWithKey 1 (\_ _ -> Nothing) k
        tell =<< gets ExpiringMap.assocs

prop_expiringMapWorks :: Int -> [Int] -> QC.Property
prop_expiringMapWorks baseGen keys = Just keys === traverse (flip ExpiringMap.lookup m) keys
  where
    m = foldr (\x -> ExpiringMap.insert futureGen x x) (ExpiringMap.new baseGen) keys
    futureGen = succ baseGen

ulength :: (Ord a, Foldable t) => t a -> Int
ulength = Set.size . Set.fromList . toList

prop_expiringMapExpires :: Int -> [Int] -> QC.Property
prop_expiringMapExpires baseGen keys = (ulength keys, futureGen, ulength keys) === ExpiringMap.inspect m1 .&&. (0, lastGen, 0) === ExpiringMap.inspect m2
  where
    m1 = ExpiringMap.newGen futureGen $ foldr (\x -> ExpiringMap.insert futureGen x x) (ExpiringMap.new baseGen) keys
    m2 = ExpiringMap.newGen lastGen m1
    futureGen = succ baseGen
    lastGen = succ futureGen

prop_expiringMapCannotAcceptExpired :: Positive Int -> Positive Int -> Int -> QC.Property
prop_expiringMapCannotAcceptExpired (Positive lowGen) (Positive offset) k = ExpiringMap.inspect m === ExpiringMap.inspect m'
  where
    highGen = lowGen + offset
    m = ExpiringMap.new highGen :: ExpiringMap.Map Int Int Int
    m' = ExpiringMap.insert lowGen k k m

prop_expiringMapUpdateMissing :: Int -> Int -> QC.Property
prop_expiringMapUpdateMissing gen k = mv === Nothing .&&. ExpiringMap.inspect m === ExpiringMap.inspect m'
  where
    m = ExpiringMap.new gen :: ExpiringMap.Map Int Int Bool
    (mv, m') = ExpiringMap.updateLookupWithKey gen (\_ _ -> Just True) k m

prop_expiringMapCannotUpdateExpired :: Positive Int -> Positive Int -> Int -> QC.Property
prop_expiringMapCannotUpdateExpired (Positive lowGen) (Positive offset) k = mv === Nothing .&&. ExpiringMap.lookup k m' === Just True
  where
    highGen = lowGen + offset
    m = ExpiringMap.insert highGen k True $ ExpiringMap.new highGen
    (mv, m') = ExpiringMap.updateLookupWithKey lowGen (\_ _ -> Just False) k m

prop_expiringMapDelete :: Int -> [Int] -> QC.Property
prop_expiringMapDelete baseGen keys = (ulength keys, baseGen, ulength keys) === ExpiringMap.inspect m .&&. (0, baseGen, 0) === ExpiringMap.inspect m'
  where
    m = foldr (\x -> ExpiringMap.insert futureGen x x) (ExpiringMap.new baseGen) keys
    m' = foldr (\x -> ExpiringMap.delete x) m keys
    futureGen = succ baseGen

prop_expiringMapElems :: Int -> Set Int -> QC.Property
prop_expiringMapElems baseGen keys = keys === Set.fromList (toList m)
  where
    m = foldr (\x -> ExpiringMap.insert futureGen x x) (ExpiringMap.new baseGen) keys
    futureGen = succ baseGen

prop_expiringMapGen :: Int -> Int -> QC.Property
prop_expiringMapGen g1 g2 = ExpiringMap.inspect m === (0, max g1 g2, 0)
  where
    m :: ExpiringMap.Map Int Int Int
    m = ExpiringMap.newGen g2 $ ExpiringMap.new g1

testExpiringMap :: [TestTree]
testExpiringMap = [
  testProperty "works" prop_expiringMapWorks,
  testProperty "expires" prop_expiringMapExpires,
  testProperty "cannot insert expired items" prop_expiringMapCannotAcceptExpired,
  testProperty "cannot update expired items" prop_expiringMapCannotUpdateExpired,
  testProperty "can't update missing items" prop_expiringMapUpdateMissing,
  testProperty "delete cleans up" prop_expiringMapDelete,
  testProperty "toList" prop_expiringMapElems,
  testProperty "generation never decreases" prop_expiringMapGen,
  localOption (QC.QuickCheckTests 10000) $ testProperty "compares to regular map" prop_expMapDoesMapStuff
  ]

tests :: [TestTree]
tests = [
  localOption (QC.QuickCheckTests 10000) $ testProperty "header length rt (parser)" prop_rtLengthParser,

  testCase "rt some packets" testPacketRT,
  localOption (QC.QuickCheckTests 1000) $ testProperty "rt packets 3.11" prop_PacketRT311,
  localOption (QC.QuickCheckTests 1000) $ testProperty "rt packets 5.0" prop_PacketRT50,
  localOption (QC.QuickCheckTests 1000) $ testProperty "rt property" prop_PropertyRT,
  testProperty "rt properties" prop_PropertiesRT,
  testProperty "sub options" prop_SubOptionsRT,
  testCase "qosFromInt" testQoSFromInt,

  testGroup "expiring map" testExpiringMap,
  testGroup "decaying map" testDecayingMap,

  testProperty "conn reasons" (byteRT :: ConnACKRC -> Bool),
  testProperty "disco reasons" (byteRT :: DiscoReason -> Bool),

  testProperties "topic semigroup" (unbatch $ semigroup (undefined :: Topic, undefined :: Int)),
  testProperties "filter semigroup" (unbatch $ semigroup (undefined :: Filter, undefined :: Int)),

  testGroup "topic matching" testTopicMatching,
  testProperty "arbitrary topic matching" prop_TopicMatching
  ]

main :: IO ()
main = defaultMain $ testGroup "All Tests" tests
