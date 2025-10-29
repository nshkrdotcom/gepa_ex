# Phase 2 Implementation Plan - TDD Approach

**Method:** Test-Driven Development (Red/Green/Refactor)
**Timeline:** 4-6 weeks
**Goal:** Core completeness with excellent test coverage

---

## TDD Cycle for Phase 2

### Red/Green/Refactor Pattern

**RED:** Write failing test
**GREEN:** Make it pass (simplest implementation)
**REFACTOR:** Improve code while keeping tests green

Repeat for each feature!

---

## Feature 1: Merge Proposer (Weeks 1-2)

### TDD Sequence

#### 1. Utility: find_dominator_programs/2
```
RED:   Write test expecting dominator programs from Pareto front
GREEN: Implement to find programs that dominate others
REFACTOR: Optimize algorithm, add edge case handling
```

#### 2. Utility: find_common_ancestor_pair/6
```
RED:   Write test for finding pairs with common ancestors
GREEN: Implement graph traversal to find ancestors
REFACTOR: Optimize traversal, handle cycles
```

#### 3. Utility: filter_ancestors/5
```
RED:   Write test for filtering valid ancestors
GREEN: Implement filtering logic
REFACTOR: Simplify conditions
```

#### 4. Utility: does_triplet_have_desirable_predictors/4
```
RED:   Write test for predictor diversity check
GREEN: Implement predictor comparison
REFACTOR: Clean up logic
```

#### 5. Module: GEPA.Proposer.Merge
```
RED:   Write test for merge scheduling
GREEN: Implement scheduling logic
REFACTOR: Simplify state management

RED:   Write test for parent selection
GREEN: Implement selection algorithm
REFACTOR: Optimize selection

RED:   Write test for predictor merging
GREEN: Implement merge logic
REFACTOR: Handle edge cases

RED:   Write test for subsample evaluation
GREEN: Implement evaluation
REFACTOR: Optimize subsample selection

RED:   Write integration test with Engine
GREEN: Integrate with Engine loop
REFACTOR: Clean up interfaces
```

#### 6. Property Tests
```
RED:   Write property: merged child not worse than max(parents)
GREEN: Ensure merge logic satisfies property
REFACTOR: Improve merge algorithm

RED:   Write property: no duplicate merges
GREEN: Implement deduplication
REFACTOR: Optimize tracking
```

---

## Feature 2: Incremental Evaluation (Week 3)

### TDD Sequence

#### 1. Module: IncrementalEvaluationPolicy
```
RED:   Write test for initial sample selection
GREEN: Implement sample selection
REFACTOR: Optimize algorithm

RED:   Write test for progressive expansion
GREEN: Implement expansion logic
REFACTOR: Simplify conditions

RED:   Write test for score estimation
GREEN: Implement estimation
REFACTOR: Improve accuracy
```

#### 2. State Integration
```
RED:   Write test for tracking evaluated samples
GREEN: Update State to track samples
REFACTOR: Optimize data structure

RED:   Write test for conditional full evaluation
GREEN: Implement conditional logic
REFACTOR: Clean up branches
```

#### 3. Engine Integration
```
RED:   Write integration test
GREEN: Integrate with Engine
REFACTOR: Simplify interface
```

---

## Feature 3: Instruction Templates (Week 4)

### TDD Sequence

#### 1. Template Validation
```
RED:   Write test for placeholder detection
GREEN: Implement validation
REFACTOR: Add helpful error messages
```

#### 2. Template Rendering
```
RED:   Write test for placeholder replacement
GREEN: Implement replacement logic
REFACTOR: Handle edge cases

RED:   Write test for markdown formatting
GREEN: Implement markdown renderer
REFACTOR: Improve formatting
```

#### 3. Output Parsing
```
RED:   Write test for code block extraction
GREEN: Implement extraction with regex
REFACTOR: Handle malformed responses

RED:   Write test for instruction extraction
GREEN: Implement extraction
REFACTOR: Robust error handling
```

#### 4. Integration
```
RED:   Write test for custom templates
GREEN: Integrate with Reflective proposer
REFACTOR: Clean up API
```

---

## Feature 4: Stop Conditions (Week 5)

### TDD Sequence

#### 1. Timeout Condition
```
RED:   Write test for time-based stopping
GREEN: Implement timeout check
REFACTOR: Support wall clock and CPU time
```

#### 2. NoImprovement Condition
```
RED:   Write test for patience tracking
GREEN: Implement improvement tracking
REFACTOR: Optimize state management
```

#### 3. Signal Handling (Optional)
```
RED:   Write test for SIGINT handling
GREEN: Implement signal trap
REFACTOR: Graceful cleanup
```

---

## TDD Best Practices for Phase 2

### Test First, Always
1. Write the test BEFORE any implementation
2. Run test, see it fail (RED)
3. Write minimal code to pass (GREEN)
4. Improve code while keeping tests green (REFACTOR)

### Good Test Characteristics
- **Descriptive names**: "test merge finds common ancestor when parents share history"
- **Single focus**: One concept per test
- **Fast**: < 100ms per test
- **Independent**: No test interdependencies
- **Deterministic**: Same input = same output

### Red/Green/Refactor Examples

#### Example: Merge Proposer Test

**RED Phase:**
```elixir
test "finds programs that dominate others on Pareto front" do
  programs = [0, 1, 2, 3]  # Program IDs
  scores = %{0 => 0.5, 1 => 0.7, 2 => 0.8, 3 => 0.6}

  dominators = GEPA.Utils.find_dominator_programs(programs, scores)

  # Expect program 2 (0.8) dominates others
  assert 2 in dominators
  assert 0 not in dominators  # 0.5 dominated by others
end
```
Run: `mix test` → **FAILS** (function doesn't exist) ✅ RED

**GREEN Phase:**
```elixir
defmodule GEPA.Utils do
  def find_dominator_programs(programs, scores) do
    # Simplest implementation that passes
    max_score = scores |> Map.values() |> Enum.max()
    Enum.filter(programs, fn p -> scores[p] == max_score end)
  end
end
```
Run: `mix test` → **PASSES** ✅ GREEN

**REFACTOR Phase:**
```elixir
defmodule GEPA.Utils do
  def find_dominator_programs(programs, scores) do
    # More sophisticated: find programs not dominated
    threshold = calculate_dominance_threshold(scores)

    programs
    |> Enum.filter(fn p -> scores[p] >= threshold end)
    |> Enum.sort_by(fn p -> -scores[p] end)
  end

  defp calculate_dominance_threshold(scores) do
    values = Map.values(scores)
    mean = Enum.sum(values) / length(values)
    std_dev = calculate_std_dev(values, mean)
    max(mean + std_dev, Enum.max(values) * 0.8)
  end
end
```
Run: `mix test` → **STILL PASSES** ✅ Refactored

---

## Development Workflow

### Daily TDD Cycle

**Morning (2-4 hours):**
1. Pick next feature from todo list
2. Write 3-5 failing tests (RED)
3. Run `mix test` - confirm failures
4. Implement to make tests pass (GREEN)
5. Run `mix test` - confirm passes
6. Commit: "feat: add [feature] (tests passing)"

**Afternoon (2-4 hours):**
7. Review implementation
8. Refactor for clarity/performance (REFACTOR)
9. Run `mix test` - ensure still passing
10. Run `mix coveralls` - check coverage
11. Run `mix dialyzer` - check types
12. Commit: "refactor: improve [feature]"

**End of Day:**
13. Update todo list
14. Run full test suite
15. Check coverage targets
16. Plan next day's tests

---

## Coverage Targets

### Maintain >80% Overall
- Phase 1 achieved: 80.4%
- Phase 2 target: 82%+
- Each new module: >85%

### Per Module Targets
- Merge utilities: 90%+
- Proposer.Merge: 85%+
- IncrementalEval: 85%+
- Templates: 90%+
- Stop conditions: 90%+

### How to Achieve
1. Write tests FIRST
2. Test all public functions
3. Test error paths
4. Test edge cases
5. Add property tests for invariants

---

## Testing Strategy

### Unit Tests
- Test each function in isolation
- Mock dependencies
- Fast (<1ms per test)
- Comprehensive coverage

### Integration Tests
- Test module interactions
- Use real State
- Test with Engine
- Validate end-to-end

### Property Tests
- Merge correctness properties
- Genealogy invariants
- Score improvements
- No duplicate merges

### Example Tests
- Validate examples still work
- Test with new features
- Ensure backward compatibility

---

## Refactoring Guidelines

### When to Refactor
- ✅ After tests are GREEN
- ✅ Code duplication spotted
- ✅ Complex functions (>20 lines)
- ✅ Unclear variable names
- ✅ Performance issues

### When NOT to Refactor
- ❌ Tests are RED
- ❌ Before tests exist
- ❌ "Just because"
- ❌ Without clear improvement

### Refactoring Checklist
1. Tests are GREEN before starting
2. Run tests after each change
3. Keep changes small
4. One refactoring at a time
5. Commit after successful refactor

---

## Phase 2 Milestones

### Milestone 1: Merge Utilities (Week 1)
- ✓ find_dominator_programs/2 tested and working
- ✓ Genealogy tracking functions tested
- ✓ All utilities >90% coverage

### Milestone 2: Merge Proposer (Week 2)
- ✓ Proposer.Merge module complete
- ✓ Integration with Engine working
- ✓ Examples demonstrating merge
- ✓ >85% coverage

### Milestone 3: Incremental Eval (Week 3)
- ✓ IncrementalEvaluationPolicy complete
- ✓ State updates working
- ✓ Saves 30-50% evaluations
- ✓ >85% coverage

### Milestone 4: Templates (Week 4)
- ✓ Template system working
- ✓ Custom templates supported
- ✓ Output parsing robust
- ✓ >90% coverage

### Milestone 5: Stop Conditions (Week 5)
- ✓ All stop conditions implemented
- ✓ Tests passing
- ✓ >90% coverage

### Milestone 6: Release (Week 6)
- ✓ All features complete
- ✓ All tests passing
- ✓ >82% overall coverage
- ✓ Documentation complete
- ✓ v0.4.0 released

---

## Red/Green/Refactor Example Workflow

### Let's implement find_dominator_programs/2

**Step 1: RED - Write failing test**
```elixir
# test/gepa/utils_test.exs
test "find_dominator_programs finds high-scoring programs" do
  programs = [0, 1, 2, 3, 4]
  scores = %{0 => 0.3, 1 => 0.7, 2 => 0.9, 3 => 0.8, 4 => 0.4}

  dominators = GEPA.Utils.find_dominator_programs(programs, scores)

  # Programs 2 and 3 dominate (top performers)
  assert 2 in dominators
  assert 3 in dominators
  # Low performers not dominators
  assert 0 not in dominators
end
```

Run: `mix test` → **FAILS** (function undefined) ✅ RED

**Step 2: GREEN - Minimal implementation**
```elixir
# lib/gepa/utils.ex
defmodule GEPA.Utils do
  def find_dominator_programs(programs, scores) do
    # Get top 2 scores
    sorted = Enum.sort_by(programs, &(-scores[&1]))
    Enum.take(sorted, 2)
  end
end
```

Run: `mix test` → **PASSES** ✅ GREEN

**Step 3: REFACTOR - Improve implementation**
```elixir
defmodule GEPA.Utils do
  @doc """
  Finds programs that dominate others on Pareto front.

  Returns programs with scores above a dominance threshold.
  """
  def find_dominator_programs(programs, scores) when is_list(programs) and is_map(scores) do
    threshold = calculate_dominance_threshold(scores)

    programs
    |> Enum.filter(fn p -> scores[p] >= threshold end)
    |> Enum.sort_by(fn p -> -scores[p] end)
  end

  defp calculate_dominance_threshold(scores) do
    values = Map.values(scores)
    max_score = Enum.max(values)
    # Dominators are within 20% of max
    max_score * 0.8
  end
end
```

Run: `mix test` → **STILL PASSES** ✅ Refactored

Run: `mix coveralls` → Check coverage

**Commit:** "feat: add find_dominator_programs with tests"

---

## Ready to Start?

I'll now:
1. Write failing tests for merge proposer utilities
2. Implement each function to make tests pass
3. Refactor for quality
4. Move to next function
5. Repeat until merge proposer complete!

**Starting with RED phase...**
