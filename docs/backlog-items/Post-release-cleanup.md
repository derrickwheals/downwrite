# Clean up items

1. [x] Fix the release workflow test step
> The release workflow’s “Run tests” step pipes swift test through tail, so it would show green even if tests failed. CI on main is what actually checks the tests. 

2. [x] Change the release version to v0.9.0