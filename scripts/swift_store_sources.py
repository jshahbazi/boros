"""Shared Swift source subset for the standalone store test scripts.

The standalone scripts (test_memory.py, test_episode.py, test_authority_*.py, and others) compile a
hand-written subset of Sources/Boros instead of the whole app. Each script's SOURCES is
STORE_CORE_SOURCES plus its own checks files and extra dependencies. When a core store file gains a
dependency on another file, add that file here once rather than to every script.
scripts/test_swift_subsets.py typechecks every script's subset so drift fails scripts/check.py.
"""

STORE_CORE_SOURCES = (
    "EpisodeBudget.swift", "EpisodeLease.swift", "EpisodeSQLFence.swift", "MemoryStore.swift", "ExchangeIndex.swift",
    "EventSourceTime.swift", "SourceTimeSchema.swift", "AuthoritySchemaSeven.swift", "AuthoritySchemaEight.swift",
    "AuthoritySchemaNine.swift", "AuthorityState.swift", "AuthorityStateJournal.swift", "AuthorityValidatedClock.swift",
    "AuthorityValidationCache.swift", "AuthorityBindings.swift", "AuthorityValidation.swift",
    "AuthorityPolicyRendering.swift", "AuthorityInputProof.swift", "AuthorityBindingJournal.swift",
    "EpisodeAccountingJournal.swift", "EpisodeTerminalCleanup.swift", "BackgroundIndexBudget.swift",
    "BackgroundIndexJournal.swift", "ContextComponentJournal.swift", "QwenTextRendering.swift",
    "ContextSourceFraming.swift", "MeteredRetrieval.swift", "HistoricalQueryFormulation.swift",
    "MeteredExchangeExpansion.swift", "BoundedNeighborhoodExpansion.swift", "ContextAssembler.swift",
)
