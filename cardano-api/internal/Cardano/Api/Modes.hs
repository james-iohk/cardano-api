{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- | Consensus modes. The node supports several different modes with different
-- combinations of consensus protocols and ledger eras.
--
module Cardano.Api.Modes (

    -- * Consensus modes
    ByronMode,
    ShelleyMode,
    CardanoMode,
    ConsensusMode(..),
    AnyConsensusMode(..),
    renderMode,
    ConsensusModeIsMultiEra(..),

    -- * The eras supported by each mode
    EraInMode(..),
    eraInModeToEra,
    anyEraInModeToAnyEra,
    AnyEraInMode(..),
    toEraInMode,

    -- * The protocols supported in each era
    ConsensusProtocol,
    ChainDepStateProtocol,

    -- * Connection parameters for each mode
    ConsensusModeParams(..),
    AnyConsensusModeParams(..),
    Byron.EpochSlots(..),

    -- * Conversions to and from types in the consensus library
    ConsensusCryptoForBlock,
    ConsensusBlockForMode,
    ConsensusBlockForEra,
    toConsensusEraIndex,
    fromConsensusEraIndex,
  ) where

import           Cardano.Api.Eras.Core

import qualified Cardano.Chain.Slotting as Byron (EpochSlots (..))
import           Cardano.Ledger.Crypto (StandardCrypto)
import qualified Ouroboros.Consensus.Byron.Ledger as Consensus
import qualified Ouroboros.Consensus.Cardano.Block as Consensus
import qualified Ouroboros.Consensus.Cardano.ByronHFC as Consensus
import           Ouroboros.Consensus.HardFork.Combinator as Consensus (EraIndex (..), eraIndexSucc,
                   eraIndexZero)
import qualified Ouroboros.Consensus.Protocol.Praos as Consensus
import qualified Ouroboros.Consensus.Protocol.TPraos as Consensus
import qualified Ouroboros.Consensus.Shelley.HFEras as Consensus
import qualified Ouroboros.Consensus.Shelley.ShelleyHFC as Consensus

import           Data.Aeson (FromJSON (parseJSON), ToJSON (toJSON), Value)
import           Data.Aeson.Types (Parser, prependFailure, typeMismatch)
import           Data.SOP.Strict (K (K), NS (S, Z))
import           Data.Text (Text)

-- ----------------------------------------------------------------------------
-- Consensus modes
--

-- | The Byron-only consensus mode consists of only the Byron era.
--
-- This was used on the mainnet before the deployment of the multi-era
-- 'CardanoMode'. It is now of little practical use, though it illustrates
-- how a single-era consensus mode works. It may be sensible to remove this
-- at some stage.
--
data ByronMode

-- | The Shelley-only consensus mode consists of only the Shelley era.
--
-- This was used for the early Shelley testnets prior to the use of the
-- multi-era 'CardanoMode'. It is useful for setting up Shelley test networks
-- (e.g. for benchmarking) without having to go through the complication of the
-- hard fork from Byron to Shelley eras. It also shows how a single-era
-- consensus mode works. It may be replaced by other single-era modes in future.
--
data ShelleyMode

-- | The Cardano consensus mode consists of all the eras currently in use on
-- the Cardano mainnet. This is currently: the 'ByronEra'; 'ShelleyEra',
-- 'AllegraEra' and 'MaryEra', in that order.
--
-- This mode will be extended with new eras as the Cardano mainnet develops.
--
data CardanoMode

data AnyConsensusModeParams where
  AnyConsensusModeParams :: ConsensusModeParams mode -> AnyConsensusModeParams

deriving instance Show AnyConsensusModeParams

-- | This GADT provides a value-level representation of all the consensus modes.
-- This enables pattern matching on the era to allow them to be treated in a
-- non-uniform way.
--
data ConsensusMode mode where
     ByronMode   :: ConsensusMode ByronMode
     ShelleyMode :: ConsensusMode ShelleyMode
     CardanoMode :: ConsensusMode CardanoMode


deriving instance Show (ConsensusMode mode)

data AnyConsensusMode where
  AnyConsensusMode :: ConsensusMode mode -> AnyConsensusMode

deriving instance Show AnyConsensusMode

renderMode :: AnyConsensusMode -> Text
renderMode (AnyConsensusMode ByronMode) = "ByronMode"
renderMode (AnyConsensusMode ShelleyMode) = "ShelleyMode"
renderMode (AnyConsensusMode CardanoMode) = "CardanoMode"

-- | The subset of consensus modes that consist of multiple eras. Some features
-- are not supported in single-era modes (for exact compatibility without
-- using the hard fork combination at all).
--
data ConsensusModeIsMultiEra mode where
     CardanoModeIsMultiEra :: ConsensusModeIsMultiEra CardanoMode

deriving instance Show (ConsensusModeIsMultiEra mode)

toEraInMode :: CardanoEra era -> ConsensusMode mode -> Maybe (EraInMode era mode)
toEraInMode ByronEra   ByronMode   = Just ByronEraInByronMode
toEraInMode _          ByronMode   = Nothing
toEraInMode ShelleyEra ShelleyMode = Just ShelleyEraInShelleyMode
toEraInMode _          ShelleyMode = Nothing
toEraInMode ByronEra   CardanoMode = Just ByronEraInCardanoMode
toEraInMode ShelleyEra CardanoMode = Just ShelleyEraInCardanoMode
toEraInMode AllegraEra CardanoMode = Just AllegraEraInCardanoMode
toEraInMode MaryEra    CardanoMode = Just MaryEraInCardanoMode
toEraInMode AlonzoEra  CardanoMode = Just AlonzoEraInCardanoMode
toEraInMode BabbageEra CardanoMode = Just BabbageEraInCardanoMode
toEraInMode ConwayEra  CardanoMode = Just ConwayEraInCardanoMode

-- | A representation of which 'CardanoEra's are included in each
-- 'ConsensusMode'.
--
data EraInMode era mode where
     ByronEraInByronMode     :: EraInMode ByronEra   ByronMode

     ShelleyEraInShelleyMode :: EraInMode ShelleyEra ShelleyMode

     ByronEraInCardanoMode   :: EraInMode ByronEra   CardanoMode
     ShelleyEraInCardanoMode :: EraInMode ShelleyEra CardanoMode
     AllegraEraInCardanoMode :: EraInMode AllegraEra CardanoMode
     MaryEraInCardanoMode    :: EraInMode MaryEra    CardanoMode
     AlonzoEraInCardanoMode  :: EraInMode AlonzoEra  CardanoMode
     BabbageEraInCardanoMode :: EraInMode BabbageEra CardanoMode
     ConwayEraInCardanoMode  :: EraInMode ConwayEra  CardanoMode

deriving instance Show (EraInMode era mode)

deriving instance Eq (EraInMode era mode)

instance FromJSON (EraInMode ByronEra ByronMode) where
  parseJSON "ByronEraInByronMode" = pure ByronEraInByronMode
  parseJSON invalid =
      invalidJSONFailure "ByronEraInByronMode"
                         "parsing 'EraInMode ByronEra ByronMode' failed, "
                         invalid

instance FromJSON (EraInMode ShelleyEra ShelleyMode) where
  parseJSON "ShelleyEraInShelleyMode" = pure ShelleyEraInShelleyMode
  parseJSON invalid =
      invalidJSONFailure "ShelleyEraInShelleyMode"
                         "parsing 'EraInMode ShelleyEra ShelleyMode' failed, "
                         invalid

instance FromJSON (EraInMode ByronEra CardanoMode) where
  parseJSON "ByronEraInCardanoMode" = pure ByronEraInCardanoMode
  parseJSON invalid =
      invalidJSONFailure "ByronEraInCardanoMode"
                         "parsing 'EraInMode ByronEra CardanoMode' failed, "
                         invalid

instance FromJSON (EraInMode ShelleyEra CardanoMode) where
  parseJSON "ShelleyEraInCardanoMode" = pure ShelleyEraInCardanoMode
  parseJSON invalid =
      invalidJSONFailure "ShelleyEraInCardanoMode"
                         "parsing 'EraInMode ShelleyEra CardanoMode' failed, "
                         invalid

instance FromJSON (EraInMode AllegraEra CardanoMode) where
  parseJSON "AllegraEraInCardanoMode" = pure AllegraEraInCardanoMode
  parseJSON invalid =
      invalidJSONFailure "AllegraEraInCardanoMode"
                         "parsing 'EraInMode AllegraEra CardanoMode' failed, "
                         invalid

instance FromJSON (EraInMode MaryEra CardanoMode) where
  parseJSON "MaryEraInCardanoMode" = pure MaryEraInCardanoMode
  parseJSON invalid =
      invalidJSONFailure "MaryEraInCardanoMode"
                         "parsing 'EraInMode MaryEra CardanoMode' failed, "
                         invalid

instance FromJSON (EraInMode AlonzoEra CardanoMode) where
  parseJSON "AlonzoEraInCardanoMode" = pure AlonzoEraInCardanoMode
  parseJSON invalid =
      invalidJSONFailure "AlonzoEraInCardanoMode"
                         "parsing 'EraInMode AlonzoEra CardanoMode' failed, "
                         invalid

instance FromJSON (EraInMode BabbageEra CardanoMode) where
  parseJSON "BabbageEraInCardanoMode" = pure BabbageEraInCardanoMode
  parseJSON invalid =
      invalidJSONFailure "BabbageEraInCardanoMode"
                         "parsing 'EraInMode Babbage CardanoMode' failed, "
                         invalid

instance FromJSON (EraInMode ConwayEra CardanoMode) where
  parseJSON "ConwayEraInCardanoMode" = pure ConwayEraInCardanoMode
  parseJSON invalid =
      invalidJSONFailure "ConwayEraInCardanoMode"
                         "parsing 'EraInMode Conway CardanoMode' failed, "
                         invalid

invalidJSONFailure :: String -> String -> Value -> Parser a
invalidJSONFailure expectedType errorMsg invalidValue =
    prependFailure errorMsg
                   (typeMismatch expectedType invalidValue)

instance ToJSON (EraInMode era mode) where
  toJSON ByronEraInByronMode = "ByronEraInByronMode"
  toJSON ShelleyEraInShelleyMode  = "ShelleyEraInShelleyMode"
  toJSON ByronEraInCardanoMode  = "ByronEraInCardanoMode"
  toJSON ShelleyEraInCardanoMode = "ShelleyEraInCardanoMode"
  toJSON AllegraEraInCardanoMode = "AllegraEraInCardanoMode"
  toJSON MaryEraInCardanoMode = "MaryEraInCardanoMode"
  toJSON AlonzoEraInCardanoMode = "AlonzoEraInCardanoMode"
  toJSON BabbageEraInCardanoMode = "BabbageEraInCardanoMode"
  toJSON ConwayEraInCardanoMode = "ConwayEraInCardanoMode"

eraInModeToEra :: EraInMode era mode -> CardanoEra era
eraInModeToEra ByronEraInByronMode     = ByronEra
eraInModeToEra ShelleyEraInShelleyMode = ShelleyEra
eraInModeToEra ByronEraInCardanoMode   = ByronEra
eraInModeToEra ShelleyEraInCardanoMode = ShelleyEra
eraInModeToEra AllegraEraInCardanoMode = AllegraEra
eraInModeToEra MaryEraInCardanoMode    = MaryEra
eraInModeToEra AlonzoEraInCardanoMode  = AlonzoEra
eraInModeToEra BabbageEraInCardanoMode = BabbageEra
eraInModeToEra ConwayEraInCardanoMode  = ConwayEra


data AnyEraInMode mode where
     AnyEraInMode :: EraInMode era mode -> AnyEraInMode mode

deriving instance Show (AnyEraInMode mode)


anyEraInModeToAnyEra :: AnyEraInMode mode -> AnyCardanoEra
anyEraInModeToAnyEra (AnyEraInMode erainmode) =
  case erainmode of
    ByronEraInByronMode     -> AnyCardanoEra ByronEra
    ShelleyEraInShelleyMode -> AnyCardanoEra ShelleyEra
    ByronEraInCardanoMode   -> AnyCardanoEra ByronEra
    ShelleyEraInCardanoMode -> AnyCardanoEra ShelleyEra
    AllegraEraInCardanoMode -> AnyCardanoEra AllegraEra
    MaryEraInCardanoMode    -> AnyCardanoEra MaryEra
    AlonzoEraInCardanoMode  -> AnyCardanoEra AlonzoEra
    BabbageEraInCardanoMode -> AnyCardanoEra BabbageEra
    ConwayEraInCardanoMode  -> AnyCardanoEra ConwayEra


-- | The consensus-mode-specific parameters needed to connect to a local node
-- that is using each consensus mode.
--
-- It is in fact only the Byron era that requires extra parameters, but this is
-- of course inherited by the 'CardanoMode' that uses the Byron era. The reason
-- this parameter is needed stems from unfortunate design decisions from the
-- legacy Byron era. The slots per epoch are needed to be able to /decode/
-- epoch boundary blocks from the Byron era.
--
-- It is possible in future that we may be able to eliminate this parameter by
-- discovering it from the node during the initial handshake.
--
data ConsensusModeParams mode where

     ByronModeParams
       :: Byron.EpochSlots
       -> ConsensusModeParams ByronMode

     ShelleyModeParams
       :: ConsensusModeParams ShelleyMode

     CardanoModeParams
       :: Byron.EpochSlots
       -> ConsensusModeParams CardanoMode

deriving instance Show (ConsensusModeParams mode)

-- ----------------------------------------------------------------------------
-- Consensus conversion functions
--

-- | A closed type family that maps between the consensus mode (from this API)
-- and the block type used by the consensus libraries.
--
type family ConsensusBlockForMode mode where
  ConsensusBlockForMode ByronMode   = Consensus.ByronBlockHFC
  ConsensusBlockForMode ShelleyMode = Consensus.ShelleyBlockHFC (Consensus.TPraos StandardCrypto) Consensus.StandardShelley
  ConsensusBlockForMode CardanoMode = Consensus.CardanoBlock StandardCrypto

type family ConsensusBlockForEra era where
  ConsensusBlockForEra ByronEra   = Consensus.ByronBlock
  ConsensusBlockForEra ShelleyEra = Consensus.StandardShelleyBlock
  ConsensusBlockForEra AllegraEra = Consensus.StandardAllegraBlock
  ConsensusBlockForEra MaryEra    = Consensus.StandardMaryBlock
  ConsensusBlockForEra AlonzoEra  = Consensus.StandardAlonzoBlock
  ConsensusBlockForEra BabbageEra = Consensus.StandardBabbageBlock
  ConsensusBlockForEra ConwayEra = Consensus.StandardConwayBlock

type family ConsensusCryptoForBlock block where
  ConsensusCryptoForBlock Consensus.ByronBlockHFC = StandardCrypto
  ConsensusCryptoForBlock (Consensus.ShelleyBlockHFC (Consensus.TPraos StandardCrypto) Consensus.StandardShelley) = Consensus.StandardShelley
  ConsensusCryptoForBlock (Consensus.CardanoBlock StandardCrypto) = StandardCrypto

type family ConsensusProtocol era where
  ConsensusProtocol ShelleyEra = Consensus.TPraos StandardCrypto
  ConsensusProtocol AllegraEra = Consensus.TPraos StandardCrypto
  ConsensusProtocol MaryEra = Consensus.TPraos StandardCrypto
  ConsensusProtocol AlonzoEra = Consensus.TPraos StandardCrypto
  ConsensusProtocol BabbageEra = Consensus.Praos StandardCrypto
  ConsensusProtocol ConwayEra = Consensus.Praos StandardCrypto

type family ChainDepStateProtocol era where
  ChainDepStateProtocol ShelleyEra = Consensus.TPraosState StandardCrypto
  ChainDepStateProtocol AllegraEra = Consensus.TPraosState StandardCrypto
  ChainDepStateProtocol MaryEra = Consensus.TPraosState StandardCrypto
  ChainDepStateProtocol AlonzoEra = Consensus.TPraosState StandardCrypto
  ChainDepStateProtocol BabbageEra = Consensus.PraosState StandardCrypto
  ChainDepStateProtocol ConwayEra = Consensus.PraosState StandardCrypto

eraIndex0 :: Consensus.EraIndex (x0 : xs)
eraIndex0 = Consensus.eraIndexZero

eraIndex1 :: Consensus.EraIndex (x1 : x0 : xs)
eraIndex1 = eraIndexSucc eraIndex0

eraIndex2 :: Consensus.EraIndex (x2 : x1 : x0 : xs)
eraIndex2 = eraIndexSucc eraIndex1

eraIndex3 :: Consensus.EraIndex (x3 : x2 : x1 : x0 : xs)
eraIndex3 = eraIndexSucc eraIndex2

eraIndex4 :: Consensus.EraIndex (x4 : x3 : x2 : x1 : x0 : xs)
eraIndex4 = eraIndexSucc eraIndex3

eraIndex5 :: Consensus.EraIndex (x5 : x4 : x3 : x2 : x1 : x0 : xs)
eraIndex5 = eraIndexSucc eraIndex4

eraIndex6 :: Consensus.EraIndex (x6 : x5 : x4 : x3 : x2 : x1 : x0 : xs)
eraIndex6 = eraIndexSucc eraIndex5

toConsensusEraIndex :: ConsensusBlockForMode mode ~ Consensus.HardForkBlock xs
                    => EraInMode era mode
                    -> Consensus.EraIndex xs
toConsensusEraIndex ByronEraInByronMode     = eraIndex0
toConsensusEraIndex ShelleyEraInShelleyMode = eraIndex0

toConsensusEraIndex ByronEraInCardanoMode   = eraIndex0
toConsensusEraIndex ShelleyEraInCardanoMode = eraIndex1
toConsensusEraIndex AllegraEraInCardanoMode = eraIndex2
toConsensusEraIndex MaryEraInCardanoMode    = eraIndex3
toConsensusEraIndex AlonzoEraInCardanoMode  = eraIndex4
toConsensusEraIndex BabbageEraInCardanoMode = eraIndex5
toConsensusEraIndex ConwayEraInCardanoMode  = eraIndex6


fromConsensusEraIndex :: ConsensusBlockForMode mode ~ Consensus.HardForkBlock xs
                      => ConsensusMode mode
                      -> Consensus.EraIndex xs
                      -> AnyEraInMode mode
fromConsensusEraIndex ByronMode = fromByronEraIndex
  where
    fromByronEraIndex :: Consensus.EraIndex
                           '[Consensus.ByronBlock]
                      -> AnyEraInMode ByronMode
    fromByronEraIndex (Consensus.EraIndex (Z (K ()))) =
      AnyEraInMode ByronEraInByronMode
fromConsensusEraIndex ShelleyMode = fromShelleyEraIndex
  where
    fromShelleyEraIndex :: Consensus.EraIndex
                             '[Consensus.StandardShelleyBlock]
                        -> AnyEraInMode ShelleyMode
    fromShelleyEraIndex (Consensus.EraIndex (Z (K ()))) =
      AnyEraInMode ShelleyEraInShelleyMode


fromConsensusEraIndex CardanoMode = fromShelleyEraIndex
  where
    fromShelleyEraIndex :: Consensus.EraIndex
                             (Consensus.CardanoEras StandardCrypto)
                        -> AnyEraInMode CardanoMode
    fromShelleyEraIndex (Consensus.EraIndex (Z (K ()))) =
      AnyEraInMode ByronEraInCardanoMode

    fromShelleyEraIndex (Consensus.EraIndex (S (Z (K ())))) =
      AnyEraInMode ShelleyEraInCardanoMode

    fromShelleyEraIndex (Consensus.EraIndex (S (S (Z (K ()))))) =
      AnyEraInMode AllegraEraInCardanoMode

    fromShelleyEraIndex (Consensus.EraIndex (S (S (S (Z (K ())))))) =
      AnyEraInMode MaryEraInCardanoMode

    fromShelleyEraIndex (Consensus.EraIndex (S (S (S (S (Z (K ()))))))) =
      AnyEraInMode AlonzoEraInCardanoMode

    fromShelleyEraIndex (Consensus.EraIndex (S (S (S (S (S (Z (K ())))))))) =
      AnyEraInMode BabbageEraInCardanoMode

    fromShelleyEraIndex (Consensus.EraIndex (S (S (S (S (S (S (Z (K ()))))))))) =
      AnyEraInMode ConwayEraInCardanoMode
