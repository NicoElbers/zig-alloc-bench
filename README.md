# Goal

This repository aims to test different allocators for the Zig language. Eventually, I want this repository to contain extensive behavior test _and_ benchmarks for general purpose allocators, so that anyone trying to implement their own allocator for Zig can test and compare to known battle-tested allocators.

# Roadmap, in no particular order

- [ ] A single to command to download binaries of well known allocators
- [ ] An easy to extend set of allocator configurations
- [ ] An easy to extend set of allocator correctness tests
- [ ] An easy to extend set of allocator benchmarks
- [ ] A fuzzing infrastructure for allocator correctness
- [ ] An extensive set of allocator profiling tools
- [ ] A (likely json, or zon when that merges) schema to represent a run of allocator benchmarks
- [ ] A way to generate a graph for allocator performance over versions
- [ ] A web interface to visualize and compare different allocators
- A Zig package that exports:
  - [ ] A function to test correctness of an allocator
  - [ ] A function to benchmark an allocator, in a way comparable to in tree benchmarks
- [ ] 1 bug found in an existing allocator

# Limitations

For the forseeable future this repository will only target Linux, with the aim of windows support down the line. This means that I can more easily do all development on my own machine to get things in a working state. Implementing windows should not be fundamentally hard, but limiting to linux for now means I can freely use all its lovely statistics and api's without scratching my head on windows.
