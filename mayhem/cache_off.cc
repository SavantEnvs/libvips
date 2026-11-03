extern "C" void vips_cache_set_max(int max);

// Turn the libvips operation cache off in every fuzz/standalone binary. Upstream's harnesses (except
// vips_fuzzer) leave it at the default (100 ops), so a cached loader result keyed on libFuzzer's reused
// input buffer could outlive an input or be served for a same-size, same-pointer one. The limit is a
// plain static that VIPS_INIT does not reset, so setting it from a constructor sticks.
__attribute__((constructor)) static void
mayhem_vips_cache_off(void)
{
	vips_cache_set_max(0);
}
