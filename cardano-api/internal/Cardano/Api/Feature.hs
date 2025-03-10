{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}

{-# OPTIONS_GHC -Wno-deprecations #-}

module Cardano.Api.Feature
  ( Featured (..)
  , asFeaturedInEra
  , asFeaturedInShelleyBasedEra
  ) where

import           Cardano.Api.Eras

-- | A value only if the feature is supported in this era
data Featured feature era a where
  Featured
    :: feature era
    -- ^ The witness that the feature is supported in this era
    -> a
    -- ^ The value to use
    -> Featured feature era a

deriving instance (Eq a, Eq (feature era)) => Eq (Featured feature era a)
deriving instance (Show a, Show (feature era)) => Show (Featured feature era a)

instance Functor (Featured feature era) where
  fmap f (Featured feature a) = Featured feature (f a)

-- | Attempt to construct a 'FeatureValue' from a value and era.
-- If the feature is not supported in the era, then 'NoFeatureValue' is returned.
asFeaturedInEra :: ()
  => FeatureInEra feature
  => a
  -> CardanoEra era
  -> Maybe (Featured feature era a)
asFeaturedInEra value = featureInEra Nothing (Just . flip Featured value)

-- | Attempt to construct a 'FeatureValue' from a value and a shelley-based-era.
asFeaturedInShelleyBasedEra :: ()
  => FeatureInEra feature
  => a
  -> ShelleyBasedEra era
  -> Maybe (Featured feature era a)
asFeaturedInShelleyBasedEra value = asFeaturedInEra value . shelleyBasedToCardanoEra
