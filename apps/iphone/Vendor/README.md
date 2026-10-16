# Local llama framework

Run `python3 apps/iphone/scripts/build_llama.py --jobs 2` on a Mac with full
Xcode. The resulting `llama.xcframework` belongs here and is deliberately ignored
by Git. The app links and embeds it for iPhone/device simulator slices. Upstream
source is pinned by `configs/llama-source.lock.json`; generated binaries are not
included in source commits. See the parent README for test and signing steps.
