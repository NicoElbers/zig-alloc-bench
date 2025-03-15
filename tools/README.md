# Recording allocator

The recording allocator can wrap any zig allocator to record the entire allocation
profile of any program, so that it can be played back at a later time.

It outputs this information in the following format:
// TODO: finalize format
