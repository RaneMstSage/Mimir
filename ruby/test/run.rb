# Tiny test harness (no minitest in mruby). Files are concatenated by bin/build.rb test.
$tests = 0; $failures = 0
def test(name)
  $tests += 1
  yield
  puts "ok   #{name}"
rescue => e
  $failures += 1
  puts "FAIL #{name}: #{e.class}: #{e.message}"
  (e.backtrace || []).first(3).each { |l| puts "       #{l}" }
end
def assert_equal(exp, act) ; raise "expected #{exp.inspect}, got #{act.inspect}" unless exp == act ; end
def assert(cond, msg = "assertion failed") ; raise msg unless cond ; end
