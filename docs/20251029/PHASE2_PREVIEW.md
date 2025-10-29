# Phase 2 Preview - Core Completeness

**Target:** v0.3.0 - v0.4.0
**Timeline:** 4-6 weeks
**Goal:** Feature parity with Python GEPA core functionality
**Status:** Ready to start (Phase 1 complete!)

---

## Overview

Phase 2 focuses on implementing the remaining core GEPA algorithm features, bringing the Elixir implementation to full feature parity with the Python version's core functionality.

**Key Theme:** Algorithm Completeness

---

## Priority Features (In Implementation Order)

### 1. Merge Proposer ⚡ HIGHEST PRIORITY

**Effort:** 7-10 days | **Impact:** HIGH | **Complexity:** High

#### What It Is
A genealogy-based candidate merging strategy that combines successful candidates from the Pareto frontier to create even better solutions.

#### How It Works
1. Identifies candidates on Pareto frontier
2. Finds pairs with common ancestors
3. Intelligently merges component texts from both parents
4. Evaluates merged candidate on subsample
5. Accepts if better than both parents

#### Why It Matters
- **Core algorithm** from the GEPA paper
- **Improves optimization quality** significantly
- **Explores candidate space** more effectively
- **Essential** for full GEPA implementation

#### Implementation Tasks
```
Design
├── Genealogy graph structure
├── Ancestor traversal algorithms
└── Common ancestor detection

Utilities
├── find_dominator_programs/2
├── find_common_ancestor_pair/6
├── filter_ancestors/5
└── does_triplet_have_desirable_predictors/4

Proposer Module
├── Merge scheduling logic
├── Parent selection
├── Predictor merging strategy
├── Subsample evaluation
└── Merge deduplication

Integration
├── Engine integration
├── State updates
└── Pareto front handling

Quality
├── Unit tests for utilities
├── Integration tests
├── Property tests for correctness
└── Documentation with examples
```

#### Code Reference
Study Python implementation: `gepa/src/gepa/proposer/merge.py` (325 lines)

#### Success Criteria
- ✓ Merges create valid candidates
- ✓ Merges improve over parents (on average)
- ✓ No duplicate merges
- ✓ All tests passing (>80% coverage)
- ✓ Well-documented with examples

---

### 2. Incremental Evaluation Policy

**Effort:** 3-4 days | **Impact:** Medium | **Complexity:** Medium

#### What It Is
Progressive validation set evaluation that starts with small samples and expands only for promising candidates.

#### How It Works
1. Start with small validation sample (e.g., 10 examples)
2. If candidate looks promising, evaluate on more samples
3. If candidate looks poor, stop early
4. Saves computation on bad candidates

#### Why It Matters
- **Reduces computation** on large validation sets (100+ examples)
- **Faster iterations** by skipping full eval for poor candidates
- **Budget efficiency** - more candidates tested with same budget

#### Implementation Tasks
```
Strategy Design
├── Sample selection algorithm
├── Budget management
└── Score estimation from subsamples

Module Creation
├── IncrementalEvaluationPolicy
├── select_samples/2 implementation
├── Track evaluated samples
└── Score estimation logic

State Management
├── Track which samples evaluated per candidate
├── Score estimation and aggregation
└── Conditional full evaluation logic

Engine Integration
├── Progressive evaluation in validation
├── Early stopping for poor candidates
└── Full evaluation for promising ones

Testing & Docs
├── Unit tests
├── Integration tests
└── Documentation
```

#### Success Criteria
- ✓ Reduces validation evaluations by 30-50%
- ✓ Maintains optimization quality (within 5%)
- ✓ Tests passing
- ✓ Documented

---

### 3. Instruction Proposal Template System

**Effort:** 2-3 days | **Impact:** Medium | **Complexity:** Low-Medium

#### What It Is
Flexible template system for reflection prompts with customizable feedback formatting.

#### How It Works
1. Provides default reflection prompt template
2. Allows custom templates with placeholders
3. Renders feedback in markdown format
4. Parses LLM output to extract new instructions

#### Why It Matters
- **Customizable reflection** for different domains
- **Better prompt engineering** capabilities
- **Easier experimentation** with different reflection strategies

#### Implementation Tasks
```
Template System
├── InstructionProposal module
├── Default template (port from Python)
├── Template validation
├── Placeholder replacement (<curr_instructions>, <inputs_outputs_feedback>)
└── Markdown rendering for structured feedback

Output Parsing
├── Extract instruction from LLM response
├── Handle code blocks
├── Regex-based extraction
└── Error handling

Integration
├── Reflective proposer integration
├── Custom template support
└── Backward compatibility

Testing & Docs
├── Template validation tests
├── Parsing tests
├── Integration tests
└── Examples
```

#### Code Reference
Study Python: `gepa/src/gepa/strategies/instruction_proposal.py` (113 lines)

#### Success Criteria
- ✓ Default template works
- ✓ Custom templates supported
- ✓ Output parsing robust
- ✓ Tests passing
- ✓ Documented

---

### 4. Additional Stop Conditions

**Effort:** 1-2 days | **Impact:** Low | **Complexity:** Low

#### What It Is
More sophisticated stopping conditions beyond simple budget limits.

#### Features
- **Timeout**: Stop after X hours/minutes
- **NoImprovement**: Stop if no improvement for N iterations
- **Signal**: Graceful shutdown on SIGINT/SIGTERM

#### Implementation Tasks
```
Timeout
├── Wall clock time tracking
├── CPU time tracking (optional)
└── Tests

NoImprovement
├── Track iterations without improvement
├── Configurable patience
├── Best score tracking
└── Tests

Signal (Optional)
├── SIGINT/SIGTERM handling
├── Graceful cleanup
└── Tests

Documentation
└── Usage examples for each
```

#### Success Criteria
- ✓ All stop conditions work reliably
- ✓ Can combine multiple conditions
- ✓ Tests passing
- ✓ Documented

---

## Phase 2 Roadmap

### Week-by-Week Plan

**Week 1-2: Merge Proposer**
- Days 1-2: Design genealogy tracking
- Days 3-5: Implement utility functions
- Days 6-8: Create Proposer.Merge module
- Days 9-10: Integration, tests, docs

**Week 3: Incremental Evaluation**
- Days 1-2: Design strategy, create module
- Day 3: State management updates
- Day 4: Integration, tests, docs

**Week 4: Instruction Templates**
- Day 1: Port template from Python
- Day 2: Output parsing
- Day 3: Integration, tests, docs

**Week 5: Stop Conditions + Polish**
- Days 1-2: Implement Timeout and NoImprovement
- Days 3-5: Buffer for merge proposer complexity

**Week 6: Release Preparation**
- Testing and validation
- Documentation polish
- Example creation
- v0.4.0 release

---

## Success Metrics

### Technical
- ✓ Merge proposer working
- ✓ Incremental eval reduces computation by 30-50%
- ✓ Template system flexible
- ✓ All tests passing (>80% coverage)
- ✓ Zero Dialyzer errors

### Functional
- ✓ 80%+ feature parity with Python core
- ✓ All core algorithms implemented
- ✓ Production-ready quality maintained

### Documentation
- ✓ All new features documented
- ✓ Examples demonstrating features
- ✓ Migration guide from v0.2.0

---

## Dependencies & Prerequisites

### From Phase 1 (Complete!)
- ✅ LLM integration
- ✅ Basic adapter
- ✅ State management
- ✅ Pareto optimization

### New Dependencies
- None! (uses existing infrastructure)

### Knowledge Required
- Genealogy graph traversal
- Pareto frontier algorithms
- Template string manipulation
- Process timing/signals

---

## Risk Assessment

### High Complexity: Merge Proposer
- **Risk:** Complex genealogy tracking
- **Mitigation:** Study Python implementation carefully, implement incrementally
- **Timeline Buffer:** 2 extra days allocated

### Medium Complexity: Incremental Evaluation
- **Risk:** Score estimation accuracy
- **Mitigation:** Test thoroughly on various datasets
- **Timeline Buffer:** 1 extra day

### Low Complexity: Templates & Stop Conditions
- **Risk:** Minimal
- **Mitigation:** Straightforward ports

**Overall Risk:** Medium (well-understood requirements)

---

## What Phase 2 Enables

### For Users
1. **Better optimization quality** via merge proposer
2. **Faster iterations** with incremental evaluation
3. **Customizable prompts** with template system
4. **Flexible stopping** with more conditions

### For Developers
1. **Full algorithm** implementation
2. **Research-grade** quality
3. **Feature parity** with Python core
4. **Production deployment** confidence

### For Community
1. **Complete core** for contributions
2. **Solid foundation** for Phase 3 adapters
3. **Research reproducibility**
4. **Competitive with Python** version

---

## Post-Phase 2 Status

### What Will Be Complete
- ✅ All core GEPA algorithms
- ✅ Full optimization loop
- ✅ Merge + Reflective proposers
- ✅ Advanced sampling strategies
- ✅ Flexible evaluation policies
- ✅ Comprehensive stop conditions
- ✅ ~85% test coverage (target)

### What Remains (Phases 3-4)
- Telemetry integration
- Progress tracking
- Additional adapters (Generic, RAG)
- Performance optimization (parallel eval)
- Community infrastructure

---

## Implementation Strategy

### Recommended Approach

1. **Start with Merge Proposer** (highest value, highest risk)
   - Get the hard part done first
   - Most impactful feature
   - 2 weeks allocated

2. **Then Incremental Evaluation** (medium complexity)
   - Builds on existing State
   - Clear requirements
   - 1 week

3. **Then Templates** (straightforward port)
   - Well-defined in Python
   - Easy to test
   - 3-4 days

4. **Finish with Stop Conditions** (quick wins)
   - Simple implementations
   - Low risk
   - 1-2 days

### Testing Strategy
- Maintain >80% coverage
- Add property tests for merge correctness
- Integration tests for all features
- Example validation

### Documentation Strategy
- Document as you implement
- Add examples for each feature
- Update roadmap with progress
- Create migration guide

---

## Quick Reference

### Phase 2 At A Glance

| Feature | Effort | Impact | Complexity |
|---------|--------|--------|------------|
| Merge Proposer | 7-10 days | HIGH | High |
| Incremental Eval | 3-4 days | Medium | Medium |
| Templates | 2-3 days | Medium | Low-Medium |
| Stop Conditions | 1-2 days | Low | Low |
| **Total** | **13-19 days** | **HIGH** | **Medium** |

**With Buffer:** 4-6 weeks total

---

## Next Actions

### To Start Phase 2

1. ✅ Review Phase 1 completion (Done!)
2. Create Phase 2 design doc for merge proposer
3. Study Python `merge.py` implementation
4. Design genealogy tracking structure
5. Create GitHub issues for Phase 2 features
6. Begin merge proposer implementation

### Decision Points

**Option A: Start Phase 2 immediately**
- Begin with merge proposer design
- High momentum from Phase 1
- Could complete in 4-6 weeks

**Option B: Pause for community feedback**
- Release v0.2.0 to Hex.pm
- Gather user feedback
- Adjust priorities based on usage

**Option C: Quick wins first**
- Implement stop conditions (1-2 days)
- Then tackle merge proposer
- Build confidence with easy features

**Recommendation:** Option A (high momentum, clear goals)

---

## Summary

Phase 2 will transform GEPA Elixir from "production-ready" to "feature-complete" with all core algorithms implemented.

**Most Important:** Merge Proposer (7-10 days, high impact)
**Quickest Win:** Stop Conditions (1-2 days)
**Total Timeline:** 4-6 weeks to v0.4.0

**Ready to begin?** Phase 1 foundation is solid, all prerequisites met, clear path forward!

---

**See Also:**
- `roadmap.md` - Complete roadmap to v1.0.0
- `implementation_gap_analysis.md` - What remains
- `COMPLETE.md` - Phase 1 final report

**Status:** Ready for Phase 2! 🚀
