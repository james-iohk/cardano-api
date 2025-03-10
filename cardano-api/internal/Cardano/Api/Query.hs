{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

-- The Shelley ledger uses promoted data kinds which we have to use, but we do
-- not export any from this API. We also use them unticked as nature intended.
{-# OPTIONS_GHC -Wno-unticked-promoted-constructors #-}


-- | Queries from local clients to the node.
--
module Cardano.Api.Query (

    -- * Queries
    QueryInMode(..),
    QueryInEra(..),
    QueryInShelleyBasedEra(..),
    QueryUTxOFilter(..),
    UTxO(..),
    UTxOInAnyEra(..),

    -- * Internal conversion functions
    toConsensusQuery,
    fromConsensusQueryResult,

    -- * Wrapper types used in queries
    SerialisedDebugLedgerState(..),
    ProtocolState(..),
    decodeProtocolState,

    DebugLedgerState(..),
    decodeDebugLedgerState,

    SerialisedCurrentEpochState(..),
    CurrentEpochState(..),
    decodeCurrentEpochState,

    SerialisedPoolState(..),
    PoolState(..),
    decodePoolState,

    SerialisedPoolDistribution(..),
    PoolDistribution(..),
    decodePoolDistribution,

    SerialisedStakeSnapshots(..),
    StakeSnapshot(..),
    decodeStakeSnapshot,

    EraHistory(..),
    SystemStart(..),

    LedgerEpochInfo(..),
    toLedgerEpochInfo,

    SlotsInEpoch(..),
    SlotsToEpochEnd(..),

    slotToEpoch,

    LedgerState(..),

    getProgress,
    getSlotForRelativeTime,

    -- * Internal conversion functions
    toLedgerUTxO,
    fromLedgerUTxO,
  ) where

import           Cardano.Api.Address
import           Cardano.Api.Block
import           Cardano.Api.Certificate
import           Cardano.Api.EraCast
import           Cardano.Api.Eras
import           Cardano.Api.GenesisParameters
import           Cardano.Api.IPC.Version
import           Cardano.Api.Keys.Shelley
import           Cardano.Api.Modes
import           Cardano.Api.NetworkId
import           Cardano.Api.ProtocolParameters
import           Cardano.Api.Query.Types
import           Cardano.Api.TxBody
import           Cardano.Api.Value

import qualified Cardano.Chain.Update.Validation.Interface as Byron.Update
import           Cardano.Ledger.Binary
import qualified Cardano.Ledger.Binary.Plain as Plain
import           Cardano.Ledger.Core (EraCrypto)
import qualified Cardano.Ledger.Credential as Shelley
import           Cardano.Ledger.Crypto (Crypto)
import           Cardano.Ledger.SafeHash (SafeHash)
import qualified Cardano.Ledger.Shelley.API as Shelley
import qualified Cardano.Ledger.Shelley.Core as Core
import qualified Cardano.Ledger.Shelley.LedgerState as Shelley
import           Cardano.Slotting.EpochInfo (hoistEpochInfo)
import           Cardano.Slotting.Slot (WithOrigin (..))
import           Cardano.Slotting.Time (SystemStart (..))
import           Ouroboros.Consensus.BlockchainTime.WallClock.Types (RelativeTime, SlotLength)
import qualified Ouroboros.Consensus.Byron.Ledger as Consensus
import           Ouroboros.Consensus.Cardano.Block (LedgerState (..), StandardCrypto)
import qualified Ouroboros.Consensus.Cardano.Block as Consensus
import qualified Ouroboros.Consensus.HardFork.Combinator as Consensus
import           Ouroboros.Consensus.HardFork.Combinator.AcrossEras (EraMismatch)
import qualified Ouroboros.Consensus.HardFork.Combinator.AcrossEras as Consensus
import qualified Ouroboros.Consensus.HardFork.Combinator.Degenerate as Consensus
import qualified Ouroboros.Consensus.HardFork.History as Consensus
import qualified Ouroboros.Consensus.HardFork.History as History
import qualified Ouroboros.Consensus.HardFork.History.Qry as Qry
import qualified Ouroboros.Consensus.Ledger.Query as Consensus
import qualified Ouroboros.Consensus.Protocol.Abstract as Consensus
import qualified Ouroboros.Consensus.Shelley.Ledger as Consensus
import           Ouroboros.Network.Block (Serialised (..))
import           Ouroboros.Network.NodeToClient.Version (NodeToClientVersion (..))
import           Ouroboros.Network.Protocol.LocalStateQuery.Client (Some (..))

import           Control.Monad (forM)
import           Control.Monad.Trans.Except
import           Data.Aeson (FromJSON (..), ToJSON (..), withObject)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KeyMap
import           Data.Aeson.Types (Parser)
import           Data.Bifunctor (bimap, first)
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as LBS
import           Data.Either.Combinators (rightToMaybe)
import qualified Data.HashMap.Strict as HMS
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Maybe (mapMaybe)
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.SOP.Strict (SListI)
import           Data.Text (Text)
import qualified Data.Text as Text
import           Data.Word (Word64)


-- ----------------------------------------------------------------------------
-- Queries
--

data QueryInMode mode result where
  QueryCurrentEra
    :: ConsensusModeIsMultiEra mode
    -> QueryInMode mode AnyCardanoEra

  QueryInEra
    :: EraInMode era mode
    -> QueryInEra era result
    -> QueryInMode mode (Either EraMismatch result)

  QueryEraHistory
    :: ConsensusModeIsMultiEra mode
    -> QueryInMode mode (EraHistory mode)

  QuerySystemStart
    :: QueryInMode mode SystemStart

  QueryChainBlockNo
    :: QueryInMode mode (WithOrigin BlockNo)

  QueryChainPoint
    :: ConsensusMode mode
    -> QueryInMode mode ChainPoint

instance NodeToClientVersionOf (QueryInMode mode result) where
  nodeToClientVersionOf (QueryCurrentEra _) = NodeToClientV_9
  nodeToClientVersionOf (QueryInEra _ q) = nodeToClientVersionOf q
  nodeToClientVersionOf (QueryEraHistory _) = NodeToClientV_9
  nodeToClientVersionOf QuerySystemStart = NodeToClientV_9
  nodeToClientVersionOf QueryChainBlockNo = NodeToClientV_10
  nodeToClientVersionOf (QueryChainPoint _) = NodeToClientV_10

data EraHistory mode where
  EraHistory
    :: ConsensusBlockForMode mode ~ Consensus.HardForkBlock xs
    => ConsensusMode mode
    -> History.Interpreter xs
    -> EraHistory mode

getProgress :: SlotNo -> EraHistory mode -> Either Qry.PastHorizonException (RelativeTime, SlotLength)
getProgress slotNo (EraHistory _ interpreter) = Qry.interpretQuery interpreter (Qry.slotToWallclock slotNo)

-- | Returns the slot number for provided relative time from 'SystemStart'
getSlotForRelativeTime :: RelativeTime -> EraHistory mode -> Either Qry.PastHorizonException SlotNo
getSlotForRelativeTime relTime (EraHistory _ interpreter) = do
  (slotNo, _, _) <- Qry.interpretQuery interpreter $ Qry.wallclockToSlot relTime
  pure slotNo

newtype LedgerEpochInfo = LedgerEpochInfo { unLedgerEpochInfo :: Consensus.EpochInfo (Either Text) }

toLedgerEpochInfo :: EraHistory mode -> LedgerEpochInfo
toLedgerEpochInfo (EraHistory _ interpreter) =
    LedgerEpochInfo $ hoistEpochInfo (first (Text.pack . show) . runExcept) $
      Consensus.interpreterToEpochInfo interpreter

--TODO: add support for these
--     QueryEraStart   :: ConsensusModeIsMultiEra mode
--                     -> EraInMode era mode
--                     -> QueryInMode mode (Maybe EraStart)

newtype SlotsInEpoch = SlotsInEpoch Word64

newtype SlotsToEpochEnd = SlotsToEpochEnd Word64

slotToEpoch :: SlotNo -> EraHistory mode -> Either Qry.PastHorizonException (EpochNo, SlotsInEpoch, SlotsToEpochEnd)
slotToEpoch slotNo (EraHistory _ interpreter) = case Qry.interpretQuery interpreter (Qry.slotToEpoch slotNo) of
  Right (epochNumber, slotsInEpoch, slotsToEpochEnd) -> Right (epochNumber, SlotsInEpoch slotsInEpoch, SlotsToEpochEnd slotsToEpochEnd)
  Left e -> Left e

deriving instance Show (QueryInMode mode result)

data QueryInEra era result where
     QueryByronUpdateState :: QueryInEra ByronEra ByronUpdateState

     QueryInShelleyBasedEra :: ShelleyBasedEra era
                            -> QueryInShelleyBasedEra era result
                            -> QueryInEra era result

instance NodeToClientVersionOf (QueryInEra era result) where
  nodeToClientVersionOf QueryByronUpdateState = NodeToClientV_9
  nodeToClientVersionOf (QueryInShelleyBasedEra _ q) = nodeToClientVersionOf q

deriving instance Show (QueryInEra era result)


data QueryInShelleyBasedEra era result where
  QueryEpoch
    :: QueryInShelleyBasedEra era EpochNo

  QueryGenesisParameters
    :: QueryInShelleyBasedEra era GenesisParameters

  QueryProtocolParameters
    :: QueryInShelleyBasedEra era ProtocolParameters

  QueryProtocolParametersUpdate
    :: QueryInShelleyBasedEra era
            (Map (Hash GenesisKey) ProtocolParametersUpdate)

  QueryStakeDistribution
    :: QueryInShelleyBasedEra era (Map (Hash StakePoolKey) Rational)

  QueryUTxO
    :: QueryUTxOFilter
    -> QueryInShelleyBasedEra era (UTxO era)

  QueryStakeAddresses
    :: Set StakeCredential
    -> NetworkId
    -> QueryInShelleyBasedEra era (Map StakeAddress Lovelace, Map StakeAddress PoolId)

  QueryStakePools
    :: QueryInShelleyBasedEra era (Set PoolId)

  QueryStakePoolParameters
    :: Set PoolId
    -> QueryInShelleyBasedEra era (Map PoolId StakePoolParameters)

     -- TODO: add support for RewardProvenance
     -- QueryPoolRanking
     --   :: QueryInShelleyBasedEra era RewardProvenance

  QueryDebugLedgerState
    :: QueryInShelleyBasedEra era (SerialisedDebugLedgerState era)

  QueryProtocolState
    :: QueryInShelleyBasedEra era (ProtocolState era)

  QueryCurrentEpochState
    :: QueryInShelleyBasedEra era (SerialisedCurrentEpochState era)

  QueryPoolState
    :: Maybe (Set PoolId)
    -> QueryInShelleyBasedEra era (SerialisedPoolState era)

  QueryPoolDistribution
    :: Maybe (Set PoolId)
    -> QueryInShelleyBasedEra era (SerialisedPoolDistribution era)

  QueryStakeSnapshot
    :: Maybe (Set PoolId)
    -> QueryInShelleyBasedEra era (SerialisedStakeSnapshots era)

  QueryStakeDelegDeposits
    :: Set StakeCredential
    -> QueryInShelleyBasedEra era (Map StakeCredential Lovelace)

  QueryConstitutionHash
    :: QueryInShelleyBasedEra era (Maybe (SafeHash (EraCrypto (ShelleyLedgerEra era)) ByteString))


instance NodeToClientVersionOf (QueryInShelleyBasedEra era result) where
  nodeToClientVersionOf QueryEpoch = NodeToClientV_9
  nodeToClientVersionOf QueryGenesisParameters = NodeToClientV_9
  nodeToClientVersionOf QueryProtocolParameters = NodeToClientV_9
  nodeToClientVersionOf QueryProtocolParametersUpdate = NodeToClientV_9
  nodeToClientVersionOf QueryStakeDistribution = NodeToClientV_9
  nodeToClientVersionOf (QueryUTxO f) = nodeToClientVersionOf f
  nodeToClientVersionOf (QueryStakeAddresses _ _) = NodeToClientV_9
  nodeToClientVersionOf QueryStakePools = NodeToClientV_9
  nodeToClientVersionOf (QueryStakePoolParameters _) = NodeToClientV_9
  nodeToClientVersionOf QueryDebugLedgerState = NodeToClientV_9
  nodeToClientVersionOf QueryProtocolState = NodeToClientV_9
  nodeToClientVersionOf QueryCurrentEpochState = NodeToClientV_9
  nodeToClientVersionOf (QueryPoolState _) = NodeToClientV_14
  nodeToClientVersionOf (QueryPoolDistribution _) = NodeToClientV_14
  nodeToClientVersionOf (QueryStakeSnapshot _) = NodeToClientV_14
  nodeToClientVersionOf (QueryStakeDelegDeposits _) = NodeToClientV_15
  nodeToClientVersionOf QueryConstitutionHash = NodeToClientV_15

deriving instance Show (QueryInShelleyBasedEra era result)


-- ----------------------------------------------------------------------------
-- Wrapper types used in queries
--

-- | Getting the /whole/ UTxO is obviously not efficient since the result can
-- be huge. Filtering by address is also not efficient because it requires a
-- linear search.
--
-- The 'QueryUTxOFilterByTxIn' is efficient since it fits with the structure of
-- the UTxO (which is indexed by 'TxIn').
--
data QueryUTxOFilter =
     -- | /O(n) time and space/ for utxo size n
     QueryUTxOWhole

     -- | /O(n) time, O(m) space/ for utxo size n, and address set size m
   | QueryUTxOByAddress (Set AddressAny)

     -- | /O(m log n) time, O(m) space/ for utxo size n, and address set size m
   | QueryUTxOByTxIn (Set TxIn)
  deriving (Eq, Show)

instance NodeToClientVersionOf QueryUTxOFilter where
  nodeToClientVersionOf QueryUTxOWhole = NodeToClientV_9
  nodeToClientVersionOf (QueryUTxOByAddress _) = NodeToClientV_9
  nodeToClientVersionOf (QueryUTxOByTxIn _) = NodeToClientV_9

newtype ByronUpdateState = ByronUpdateState Byron.Update.State
  deriving Show

newtype UTxO era = UTxO { unUTxO :: Map TxIn (TxOut CtxUTxO era) }
  deriving (Eq, Show)

instance EraCast UTxO where
  eraCast toEra' (UTxO m) = UTxO <$> forM m (eraCast toEra')

data UTxOInAnyEra where
  UTxOInAnyEra :: CardanoEra era
               -> UTxO era
               -> UTxOInAnyEra

deriving instance Show UTxOInAnyEra

instance IsCardanoEra era => ToJSON (UTxO era) where
  toJSON (UTxO m) = toJSON m
  toEncoding (UTxO m) = toEncoding m

instance (IsShelleyBasedEra era, FromJSON (TxOut CtxUTxO era))
  => FromJSON (UTxO era) where
    parseJSON = withObject "UTxO" $ \hm -> do
      let l = HMS.toList $ KeyMap.toHashMapText hm
      res <- mapM toTxIn l
      pure . UTxO $ Map.fromList res
     where
      toTxIn :: (Text, Aeson.Value) -> Parser (TxIn, TxOut CtxUTxO era)
      toTxIn (txinText, txOutVal) = do
        (,) <$> parseJSON (Aeson.String txinText)
            <*> parseJSON txOutVal

newtype SerialisedDebugLedgerState era
  = SerialisedDebugLedgerState (Serialised (Shelley.NewEpochState (ShelleyLedgerEra era)))

decodeDebugLedgerState :: forall era. ()
  => FromCBOR (DebugLedgerState era)
  => SerialisedDebugLedgerState era
  -> Either LBS.ByteString (DebugLedgerState era)
decodeDebugLedgerState (SerialisedDebugLedgerState (Serialised ls)) =
  first (const ls) (Plain.decodeFull ls)

newtype ProtocolState era
  = ProtocolState (Serialised (Consensus.ChainDepState (ConsensusProtocol era)))

-- ChainDepState can use Praos or TPraos crypto
decodeProtocolState
  :: FromCBOR (Consensus.ChainDepState (ConsensusProtocol era))
  => ProtocolState era
  -> Either (LBS.ByteString, DecoderError) (Consensus.ChainDepState (ConsensusProtocol era))
decodeProtocolState (ProtocolState (Serialised pbs)) = first (pbs,) $ Plain.decodeFull pbs

newtype SerialisedCurrentEpochState era
  = SerialisedCurrentEpochState (Serialised (Shelley.EpochState (ShelleyLedgerEra era)))

newtype CurrentEpochState era = CurrentEpochState (Shelley.EpochState (ShelleyLedgerEra era))

decodeCurrentEpochState
  :: ShelleyBasedEra era
  -> SerialisedCurrentEpochState era
  -> Either DecoderError (CurrentEpochState era)
decodeCurrentEpochState sbe (SerialisedCurrentEpochState (Serialised ls)) =
  CurrentEpochState <$>
    case sbe of
      ShelleyBasedEraShelley -> Plain.decodeFull ls
      ShelleyBasedEraAllegra -> Plain.decodeFull ls
      ShelleyBasedEraMary    -> Plain.decodeFull ls
      ShelleyBasedEraAlonzo  -> Plain.decodeFull ls
      ShelleyBasedEraBabbage -> Plain.decodeFull ls
      ShelleyBasedEraConway  -> Plain.decodeFull ls


newtype SerialisedPoolState era
  = SerialisedPoolState (Serialised (Shelley.PState (ShelleyLedgerEra era)))

newtype PoolState era = PoolState (Shelley.PState (ShelleyLedgerEra era))

decodePoolState
  :: forall era. ()
  => Core.Era (ShelleyLedgerEra era)
  => DecCBOR (Shelley.PState (ShelleyLedgerEra era))
  => SerialisedPoolState era
  -> Either DecoderError (PoolState era)
decodePoolState (SerialisedPoolState (Serialised ls)) =
  PoolState <$> decodeFull (Core.eraProtVerLow @(ShelleyLedgerEra era)) ls

newtype SerialisedPoolDistribution era
  = SerialisedPoolDistribution (Serialised (Shelley.PoolDistr (Core.EraCrypto (ShelleyLedgerEra era))))

newtype PoolDistribution era = PoolDistribution
  { unPoolDistr :: Shelley.PoolDistr (Core.EraCrypto (ShelleyLedgerEra era))
  }

decodePoolDistribution
  :: forall era. (Crypto (Core.EraCrypto (ShelleyLedgerEra era)))
  => ShelleyBasedEra era
  -> SerialisedPoolDistribution era
  -> Either DecoderError (PoolDistribution era)
decodePoolDistribution sbe (SerialisedPoolDistribution (Serialised ls)) =
  PoolDistribution <$> decodeFull (eraProtVerLow sbe) ls

newtype SerialisedStakeSnapshots era
  = SerialisedStakeSnapshots (Serialised (Consensus.StakeSnapshots (Core.EraCrypto (ShelleyLedgerEra era))))

newtype StakeSnapshot era = StakeSnapshot (Consensus.StakeSnapshots (Core.EraCrypto (ShelleyLedgerEra era)))

decodeStakeSnapshot
  :: forall era. ()
  => FromCBOR (Consensus.StakeSnapshots (Core.EraCrypto (ShelleyLedgerEra era)))
  => SerialisedStakeSnapshots era
  -> Either DecoderError (StakeSnapshot era)
decodeStakeSnapshot (SerialisedStakeSnapshots (Serialised ls)) = StakeSnapshot <$> Plain.decodeFull ls

toShelleyAddrSet :: CardanoEra era
                 -> Set AddressAny
                 -> Set (Shelley.Addr Consensus.StandardCrypto)
toShelleyAddrSet era =
    Set.fromList
  . map toShelleyAddr
    -- Ignore any addresses that are not appropriate for the era,
    -- e.g. Shelley addresses in the Byron era, as these would not
    -- appear in the UTxO anyway.
  . mapMaybe (rightToMaybe . anyAddressInEra era)
  . Set.toList


toLedgerUTxO :: ShelleyLedgerEra era ~ ledgerera
             => Core.EraCrypto ledgerera ~ StandardCrypto
             => ShelleyBasedEra era
             -> UTxO era
             -> Shelley.UTxO ledgerera
toLedgerUTxO sbe (UTxO utxo) =
    Shelley.UTxO
  . Map.fromList
  . map (bimap toShelleyTxIn (toShelleyTxOut sbe))
  . Map.toList
  $ utxo

fromLedgerUTxO :: ShelleyLedgerEra era ~ ledgerera
               => Core.EraCrypto ledgerera ~ StandardCrypto
               => ShelleyBasedEra era
               -> Shelley.UTxO ledgerera
               -> UTxO era
fromLedgerUTxO sbe (Shelley.UTxO utxo) =
    UTxO
  . Map.fromList
  . map (bimap fromShelleyTxIn (fromShelleyTxOut sbe))
  . Map.toList
  $ utxo

fromShelleyPoolDistr :: Shelley.PoolDistr StandardCrypto
                     -> Map (Hash StakePoolKey) Rational
fromShelleyPoolDistr =
    --TODO: write an appropriate property to show it is safe to use
    -- Map.fromListAsc or to use Map.mapKeysMonotonic
    Map.fromList
  . map (bimap StakePoolKeyHash Shelley.individualPoolStake)
  . Map.toList
  . Shelley.unPoolDistr

fromShelleyDelegations :: Map (Shelley.Credential Shelley.Staking StandardCrypto)
                              (Shelley.KeyHash Shelley.StakePool StandardCrypto)
                       -> Map StakeCredential PoolId
fromShelleyDelegations =
    --TODO: write an appropriate property to show it is safe to use
    -- Map.fromListAsc or to use Map.mapKeysMonotonic
    -- In this case it may not be: the Ord instances for Shelley.Credential
    -- do not match the one for StakeCredential
    Map.fromList
  . map (bimap fromShelleyStakeCredential StakePoolKeyHash)
  . Map.toList

fromShelleyRewardAccounts :: Shelley.RewardAccounts Consensus.StandardCrypto
                          -> Map StakeCredential Lovelace
fromShelleyRewardAccounts =
    --TODO: write an appropriate property to show it is safe to use
    -- Map.fromListAsc or to use Map.mapKeysMonotonic
    Map.fromList
  . map (bimap fromShelleyStakeCredential fromShelleyLovelace)
  . Map.toList


-- ----------------------------------------------------------------------------
-- Conversions of queries into the consensus types.
--

toConsensusQuery :: forall mode block result.
                    ConsensusBlockForMode mode ~ block
                 => QueryInMode mode result
                 -> Some (Consensus.Query block)
toConsensusQuery (QueryCurrentEra CardanoModeIsMultiEra) =
    Some $ Consensus.BlockQuery $
      Consensus.QueryHardFork
        Consensus.GetCurrentEra

toConsensusQuery (QueryInEra ByronEraInByronMode QueryByronUpdateState) =
    Some $ Consensus.BlockQuery $
      Consensus.DegenQuery
        Consensus.GetUpdateInterfaceState

toConsensusQuery (QueryEraHistory CardanoModeIsMultiEra) =
    Some $ Consensus.BlockQuery $
      Consensus.QueryHardFork
        Consensus.GetInterpreter

toConsensusQuery QuerySystemStart = Some Consensus.GetSystemStart

toConsensusQuery QueryChainBlockNo = Some Consensus.GetChainBlockNo

toConsensusQuery (QueryChainPoint _) = Some Consensus.GetChainPoint

toConsensusQuery (QueryInEra ByronEraInCardanoMode QueryByronUpdateState) =
    Some $ Consensus.BlockQuery $
      Consensus.QueryIfCurrentByron
        Consensus.GetUpdateInterfaceState

toConsensusQuery (QueryInEra erainmode (QueryInShelleyBasedEra sbe q)) =
    case erainmode of
      ByronEraInByronMode     -> case sbe of {}
      ShelleyEraInShelleyMode -> toConsensusQueryShelleyBased erainmode q
      ByronEraInCardanoMode   -> case sbe of {}
      ShelleyEraInCardanoMode -> toConsensusQueryShelleyBased erainmode q
      AllegraEraInCardanoMode -> toConsensusQueryShelleyBased erainmode q
      MaryEraInCardanoMode    -> toConsensusQueryShelleyBased erainmode q
      AlonzoEraInCardanoMode  -> toConsensusQueryShelleyBased erainmode q
      BabbageEraInCardanoMode -> toConsensusQueryShelleyBased erainmode q
      ConwayEraInCardanoMode -> toConsensusQueryShelleyBased erainmode q


toConsensusQueryShelleyBased
  :: forall era ledgerera mode protocol block xs result.
     ConsensusBlockForEra era ~ Consensus.ShelleyBlock protocol ledgerera
  => Core.EraCrypto ledgerera ~ Consensus.StandardCrypto
  => ConsensusBlockForMode mode ~ block
  => block ~ Consensus.HardForkBlock xs
  => EraInMode era mode
  -> QueryInShelleyBasedEra era result
  -> Some (Consensus.Query block)
toConsensusQueryShelleyBased erainmode QueryEpoch =
    Some (consensusQueryInEraInMode erainmode Consensus.GetEpochNo)

toConsensusQueryShelleyBased erainmode QueryConstitutionHash =
    Some (consensusQueryInEraInMode erainmode Consensus.GetConstitutionHash)

toConsensusQueryShelleyBased erainmode QueryGenesisParameters =
    Some (consensusQueryInEraInMode erainmode Consensus.GetGenesisConfig)

toConsensusQueryShelleyBased erainmode QueryProtocolParameters =
    Some (consensusQueryInEraInMode erainmode Consensus.GetCurrentPParams)

toConsensusQueryShelleyBased erainmode QueryProtocolParametersUpdate =
    Some (consensusQueryInEraInMode erainmode Consensus.GetProposedPParamsUpdates)

toConsensusQueryShelleyBased erainmode QueryStakeDistribution =
    Some (consensusQueryInEraInMode erainmode Consensus.GetStakeDistribution)

toConsensusQueryShelleyBased erainmode (QueryUTxO QueryUTxOWhole) =
    Some (consensusQueryInEraInMode erainmode Consensus.GetUTxOWhole)

toConsensusQueryShelleyBased erainmode (QueryUTxO (QueryUTxOByAddress addrs)) =
    Some (consensusQueryInEraInMode erainmode (Consensus.GetUTxOByAddress addrs'))
  where
    addrs' :: Set (Shelley.Addr Consensus.StandardCrypto)
    addrs' = toShelleyAddrSet (eraInModeToEra erainmode) addrs

toConsensusQueryShelleyBased erainmode (QueryUTxO (QueryUTxOByTxIn txins)) =
    Some (consensusQueryInEraInMode erainmode (Consensus.GetUTxOByTxIn txins'))
  where
    txins' :: Set (Shelley.TxIn Consensus.StandardCrypto)
    txins' = Set.map toShelleyTxIn txins

toConsensusQueryShelleyBased erainmode (QueryStakeAddresses creds _nId) =
    Some (consensusQueryInEraInMode erainmode
            (Consensus.GetFilteredDelegationsAndRewardAccounts creds'))
  where
    creds' :: Set (Shelley.Credential Shelley.Staking StandardCrypto)
    creds' = Set.map toShelleyStakeCredential creds

toConsensusQueryShelleyBased erainmode QueryStakePools =
    Some (consensusQueryInEraInMode erainmode Consensus.GetStakePools)

toConsensusQueryShelleyBased erainmode (QueryStakePoolParameters poolids) =
    Some (consensusQueryInEraInMode erainmode (Consensus.GetStakePoolParams poolids'))
  where
    poolids' :: Set (Shelley.KeyHash Shelley.StakePool Consensus.StandardCrypto)
    poolids' = Set.map unStakePoolKeyHash poolids

toConsensusQueryShelleyBased erainmode QueryDebugLedgerState =
    Some (consensusQueryInEraInMode erainmode (Consensus.GetCBOR Consensus.DebugNewEpochState))

toConsensusQueryShelleyBased erainmode QueryProtocolState =
    Some (consensusQueryInEraInMode erainmode (Consensus.GetCBOR Consensus.DebugChainDepState))

toConsensusQueryShelleyBased erainmode QueryCurrentEpochState =
    Some (consensusQueryInEraInMode erainmode (Consensus.GetCBOR Consensus.DebugEpochState))

toConsensusQueryShelleyBased erainmode (QueryPoolState poolIds) =
    Some (consensusQueryInEraInMode erainmode (Consensus.GetCBOR (Consensus.GetPoolState (Set.map unStakePoolKeyHash <$> poolIds))))

toConsensusQueryShelleyBased erainmode (QueryStakeSnapshot mPoolIds) =
    Some (consensusQueryInEraInMode erainmode (Consensus.GetCBOR (Consensus.GetStakeSnapshots (fmap (Set.map unStakePoolKeyHash) mPoolIds))))

toConsensusQueryShelleyBased erainmode (QueryPoolDistribution poolIds) =
    Some (consensusQueryInEraInMode erainmode (Consensus.GetCBOR (Consensus.GetPoolDistr (getPoolIds <$> poolIds))))
  where
    getPoolIds :: Set PoolId -> Set (Shelley.KeyHash Shelley.StakePool Consensus.StandardCrypto)
    getPoolIds = Set.map (\(StakePoolKeyHash kh) -> kh)
toConsensusQueryShelleyBased erainmode (QueryStakeDelegDeposits stakeCreds) =
    Some (consensusQueryInEraInMode erainmode (Consensus.GetStakeDelegDeposits stakeCreds'))
  where
    stakeCreds' :: Set (Shelley.StakeCredential Consensus.StandardCrypto)
    stakeCreds' = Set.map toShelleyStakeCredential stakeCreds

consensusQueryInEraInMode
  :: forall era mode erablock modeblock result result' xs.
     ConsensusBlockForEra era   ~ erablock
  => ConsensusBlockForMode mode ~ modeblock
  => modeblock ~ Consensus.HardForkBlock xs
  => Consensus.HardForkQueryResult xs result ~ result'
  => EraInMode era mode
  -> Consensus.BlockQuery erablock  result
  -> Consensus.Query modeblock result'
consensusQueryInEraInMode erainmode =
    Consensus.BlockQuery
  . case erainmode of
      ByronEraInByronMode     -> Consensus.DegenQuery
      ShelleyEraInShelleyMode -> Consensus.DegenQuery
      ByronEraInCardanoMode   -> Consensus.QueryIfCurrentByron
      ShelleyEraInCardanoMode -> Consensus.QueryIfCurrentShelley
      AllegraEraInCardanoMode -> Consensus.QueryIfCurrentAllegra
      MaryEraInCardanoMode    -> Consensus.QueryIfCurrentMary
      AlonzoEraInCardanoMode  -> Consensus.QueryIfCurrentAlonzo
      BabbageEraInCardanoMode -> Consensus.QueryIfCurrentBabbage
      ConwayEraInCardanoMode -> Consensus.QueryIfCurrentConway

-- ----------------------------------------------------------------------------
-- Conversions of query results from the consensus types.
--

fromConsensusQueryResult :: forall mode block result result'. ConsensusBlockForMode mode ~ block
                         => QueryInMode mode result
                         -> Consensus.Query block result'
                         -> result'
                         -> result
fromConsensusQueryResult (QueryEraHistory CardanoModeIsMultiEra) q' r' =
    case q' of
      Consensus.BlockQuery (Consensus.QueryHardFork Consensus.GetInterpreter)
        -> EraHistory CardanoMode r'
      _ -> fromConsensusQueryResultMismatch

fromConsensusQueryResult QuerySystemStart q' r' =
    case q' of
      Consensus.GetSystemStart
        -> r'
      _ -> fromConsensusQueryResultMismatch

fromConsensusQueryResult QueryChainBlockNo q' r' =
    case q' of
      Consensus.GetChainBlockNo
        -> r'
      _ -> fromConsensusQueryResultMismatch

fromConsensusQueryResult (QueryChainPoint mode) q' r' =
    case q' of
      Consensus.GetChainPoint
        -> fromConsensusPointInMode mode r'
      _ -> fromConsensusQueryResultMismatch

fromConsensusQueryResult (QueryCurrentEra CardanoModeIsMultiEra) q' r' =
    case q' of
      Consensus.BlockQuery (Consensus.QueryHardFork Consensus.GetCurrentEra)
        -> anyEraInModeToAnyEra (fromConsensusEraIndex CardanoMode r')
      _ -> fromConsensusQueryResultMismatch

fromConsensusQueryResult (QueryInEra ByronEraInByronMode
                                     QueryByronUpdateState) q' r' =
    case (q', r') of
      (Consensus.BlockQuery (Consensus.DegenQuery Consensus.GetUpdateInterfaceState),
       Consensus.DegenQueryResult r'')
        -> Right (ByronUpdateState r'')
      _ -> fromConsensusQueryResultMismatch

fromConsensusQueryResult (QueryInEra ByronEraInCardanoMode
                                     QueryByronUpdateState) q' r' =
    case q' of
      Consensus.BlockQuery
        (Consensus.QueryIfCurrentByron Consensus.GetUpdateInterfaceState)
        -> bimap fromConsensusEraMismatch ByronUpdateState r'
      _ -> fromConsensusQueryResultMismatch

fromConsensusQueryResult (QueryInEra ByronEraInByronMode
                                     (QueryInShelleyBasedEra sbe _)) _ _ =
    case sbe of {}

fromConsensusQueryResult (QueryInEra ShelleyEraInShelleyMode
                                     (QueryInShelleyBasedEra _sbe q)) q' r' =
    case (q', r') of
      (Consensus.BlockQuery (Consensus.DegenQuery q''),
       Consensus.DegenQueryResult r'')
        -> Right (fromConsensusQueryResultShelleyBased
                    ShelleyBasedEraShelley q q'' r'')
      _ -> fromConsensusQueryResultMismatch

fromConsensusQueryResult (QueryInEra ByronEraInCardanoMode
                                     (QueryInShelleyBasedEra sbe _)) _ _ =
    case sbe of {}

fromConsensusQueryResult (QueryInEra ShelleyEraInCardanoMode
                                     (QueryInShelleyBasedEra _sbe q)) q' r' =
    case q' of
      Consensus.BlockQuery (Consensus.QueryIfCurrentShelley q'')
        -> bimap fromConsensusEraMismatch
                 (fromConsensusQueryResultShelleyBased
                    ShelleyBasedEraShelley q q'')
                 r'
      _ -> fromConsensusQueryResultMismatch

fromConsensusQueryResult (QueryInEra AllegraEraInCardanoMode
                                     (QueryInShelleyBasedEra _era q)) q' r' =
    case q' of
      Consensus.BlockQuery (Consensus.QueryIfCurrentAllegra q'')
        -> bimap fromConsensusEraMismatch
                 (fromConsensusQueryResultShelleyBased
                    ShelleyBasedEraAllegra q q'')
                 r'
      _ -> fromConsensusQueryResultMismatch

fromConsensusQueryResult (QueryInEra MaryEraInCardanoMode
                                     (QueryInShelleyBasedEra _era q)) q' r' =
    case q' of
      Consensus.BlockQuery (Consensus.QueryIfCurrentMary q'')
        -> bimap fromConsensusEraMismatch
                 (fromConsensusQueryResultShelleyBased
                    ShelleyBasedEraMary q q'')
                 r'
      _ -> fromConsensusQueryResultMismatch

fromConsensusQueryResult (QueryInEra AlonzoEraInCardanoMode
                                     (QueryInShelleyBasedEra _era q)) q' r' =
    case q' of
      Consensus.BlockQuery (Consensus.QueryIfCurrentAlonzo q'')
        -> bimap fromConsensusEraMismatch
                 (fromConsensusQueryResultShelleyBased
                    ShelleyBasedEraAlonzo q q'')
                 r'
      _ -> fromConsensusQueryResultMismatch

fromConsensusQueryResult (QueryInEra BabbageEraInCardanoMode
                                     (QueryInShelleyBasedEra _era q)) q' r' =
    case q' of
      Consensus.BlockQuery (Consensus.QueryIfCurrentBabbage q'')
        -> bimap fromConsensusEraMismatch
                 (fromConsensusQueryResultShelleyBased
                    ShelleyBasedEraBabbage q q'')
                 r'
      _ -> fromConsensusQueryResultMismatch

fromConsensusQueryResult (QueryInEra ConwayEraInCardanoMode
                                     (QueryInShelleyBasedEra _era q)) q' r' =
    case q' of
      Consensus.BlockQuery (Consensus.QueryIfCurrentConway q'')
        -> bimap fromConsensusEraMismatch
                 (fromConsensusQueryResultShelleyBased
                    ShelleyBasedEraConway q q'')
                 r'
      _ -> fromConsensusQueryResultMismatch

fromConsensusQueryResultShelleyBased
  :: forall era ledgerera protocol result result'.
     ShelleyLedgerEra era ~ ledgerera
  => Core.EraCrypto ledgerera ~ Consensus.StandardCrypto
  => ConsensusProtocol era ~ protocol
  => ShelleyBasedEra era
  -> QueryInShelleyBasedEra era result
  -> Consensus.BlockQuery (Consensus.ShelleyBlock protocol ledgerera) result'
  -> result'
  -> result
fromConsensusQueryResultShelleyBased _ QueryEpoch q' epoch =
    case q' of
      Consensus.GetEpochNo -> epoch
      _                    -> fromConsensusQueryResultMismatch

fromConsensusQueryResultShelleyBased _ QueryConstitutionHash q' mCHash =
    case q' of
      Consensus.GetConstitutionHash -> mCHash
      _                    -> fromConsensusQueryResultMismatch

fromConsensusQueryResultShelleyBased _ QueryGenesisParameters q' r' =
    case q' of
      Consensus.GetGenesisConfig -> fromShelleyGenesis
                                      (Consensus.getCompactGenesis r')
      _                          -> fromConsensusQueryResultMismatch

fromConsensusQueryResultShelleyBased sbe QueryProtocolParameters q' r' =
    case q' of
      Consensus.GetCurrentPParams -> fromLedgerPParams sbe r'
      _                           -> fromConsensusQueryResultMismatch

fromConsensusQueryResultShelleyBased sbe QueryProtocolParametersUpdate q' r' =
    case q' of
      Consensus.GetProposedPParamsUpdates -> fromLedgerProposedPPUpdates sbe r'
      _                                   -> fromConsensusQueryResultMismatch

fromConsensusQueryResultShelleyBased _ QueryStakeDistribution q' r' =
    case q' of
      Consensus.GetStakeDistribution -> fromShelleyPoolDistr r'
      _                              -> fromConsensusQueryResultMismatch

fromConsensusQueryResultShelleyBased sbe (QueryUTxO QueryUTxOWhole) q' utxo' =
    case q' of
      Consensus.GetUTxOWhole -> fromLedgerUTxO sbe utxo'
      _                      -> fromConsensusQueryResultMismatch

fromConsensusQueryResultShelleyBased sbe (QueryUTxO QueryUTxOByAddress{}) q' utxo' =
    case q' of
      Consensus.GetUTxOByAddress{} -> fromLedgerUTxO sbe utxo'
      _                            -> fromConsensusQueryResultMismatch

fromConsensusQueryResultShelleyBased sbe (QueryUTxO QueryUTxOByTxIn{}) q' utxo' =
    case q' of
      Consensus.GetUTxOByTxIn{} -> fromLedgerUTxO sbe utxo'
      _                         -> fromConsensusQueryResultMismatch

fromConsensusQueryResultShelleyBased _ (QueryStakeAddresses _ nId) q' r' =
    case q' of
      Consensus.GetFilteredDelegationsAndRewardAccounts{}
        -> let (delegs, rwaccs) = r'
           in ( Map.mapKeys (makeStakeAddress nId) $ fromShelleyRewardAccounts rwaccs
              , Map.mapKeys (makeStakeAddress nId) $ fromShelleyDelegations delegs
              )
      _ -> fromConsensusQueryResultMismatch

fromConsensusQueryResultShelleyBased _ QueryStakePools q' poolids' =
    case q' of
      Consensus.GetStakePools -> Set.map StakePoolKeyHash poolids'
      _                       -> fromConsensusQueryResultMismatch

fromConsensusQueryResultShelleyBased _ QueryStakePoolParameters{} q' poolparams' =
    case q' of
      Consensus.GetStakePoolParams{} -> Map.map fromShelleyPoolParams
                                      . Map.mapKeysMonotonic StakePoolKeyHash
                                      $ poolparams'
      _                              -> fromConsensusQueryResultMismatch

fromConsensusQueryResultShelleyBased _ QueryDebugLedgerState{} q' r' =
    case q' of
      Consensus.GetCBOR Consensus.DebugNewEpochState -> SerialisedDebugLedgerState r'
      _                                              -> fromConsensusQueryResultMismatch

fromConsensusQueryResultShelleyBased _ QueryProtocolState q' r' =
    case q' of
      Consensus.GetCBOR Consensus.DebugChainDepState -> ProtocolState r'
      _                                              -> fromConsensusQueryResultMismatch

fromConsensusQueryResultShelleyBased _ QueryCurrentEpochState q' r' =
  case q' of
    Consensus.GetCBOR Consensus.DebugEpochState -> SerialisedCurrentEpochState r'
    _                                           -> fromConsensusQueryResultMismatch

fromConsensusQueryResultShelleyBased _ QueryPoolState{} q' r' =
  case q' of
    Consensus.GetCBOR Consensus.GetPoolState {} -> SerialisedPoolState r'
    _                                           -> fromConsensusQueryResultMismatch

fromConsensusQueryResultShelleyBased _ QueryPoolDistribution{} q' r' =
  case q' of
    Consensus.GetCBOR Consensus.GetPoolDistr {} -> SerialisedPoolDistribution r'
    _                                           -> fromConsensusQueryResultMismatch

fromConsensusQueryResultShelleyBased _ QueryStakeSnapshot{} q' r' =
  case q' of
    Consensus.GetCBOR Consensus.GetStakeSnapshots {} -> SerialisedStakeSnapshots r'
    _                                                -> fromConsensusQueryResultMismatch

fromConsensusQueryResultShelleyBased _ QueryStakeDelegDeposits{} q' stakeCreds' =
    case q' of
      Consensus.GetStakeDelegDeposits{} -> Map.map fromShelleyLovelace
                                         . Map.mapKeysMonotonic fromShelleyStakeCredential
                                         $ stakeCreds'
      _                                 -> fromConsensusQueryResultMismatch

-- | This should /only/ happen if we messed up the mapping in 'toConsensusQuery'
-- and 'fromConsensusQueryResult' so they are inconsistent with each other.
--
-- If we do encounter this error it means that 'toConsensusQuery' maps a
-- API query constructor to a certain consensus query constructor but that
-- 'fromConsensusQueryResult' apparently expects a different pairing.
--
-- For example, imagine if 'toConsensusQuery would (incorrectly) map
-- 'QueryChainPoint' to 'Consensus.GetEpochNo' but 'fromConsensusQueryResult'
-- (correctly) expected to find 'Consensus.GetLedgerTip'. This mismatch would
-- trigger this error.
--
-- Such mismatches should be preventable with an appropriate property test.
--
fromConsensusQueryResultMismatch :: a
fromConsensusQueryResultMismatch =
    error "fromConsensusQueryResult: internal query mismatch"


fromConsensusEraMismatch :: SListI xs
                         => Consensus.MismatchEraInfo xs -> EraMismatch
fromConsensusEraMismatch = Consensus.mkEraMismatch
