using Progbiotic
using Aqua
using Test

# Static hygiene: ambiguities, type piracy, unbound type parameters, undefined
# exports, stale dependencies, and project/extras consistency.
#
# persistent_tasks is off deliberately: a render task lives for exactly as long as
# its bar does, and a bar may outlive the test that created it, so a lingering task
# at test-suite exit is expected rather than a leak.
@testset "quality.jl" begin
    Aqua.test_all(Progbiotic; persistent_tasks = false)
end
