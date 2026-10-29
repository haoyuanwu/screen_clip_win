# Local translation components

The local translation channel uses Argos Translate 1.9 English–Chinese and Chinese–English model archives, distributed by Argos Open Technologies. Inference uses CTranslate2 4.6.0 (MIT) and SentencePiece 0.2.1 (Apache-2.0); their installed distribution license files accompany the helper. Model archives retain their README/license and metadata after installation. Model licenses must be reviewed before redistributing models; language packs are downloaded on demand from their upstream host, not included in the app installer.

Sources:
- https://github.com/argosopentech/argospm-index
- https://github.com/argosopentech/argos-translate
- https://github.com/OpenNMT/CTranslate2
- https://github.com/google/sentencepiece

This integration uses CPU inference and bounded punctuation-based splitting for screenshot text, rather than the complete Argos Python sentence splitting pipeline. It does not include PyTorch or upload source text.

The pinned English–Chinese 1.9 model README credits Jörg Tiedemann and Santhosh Thottingal (OPUS-MT, EAMT 2020) and states the original OPUS model is CC-BY 4.0. The complete upstream README remains with each downloaded language pack.
