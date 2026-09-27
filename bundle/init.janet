(if (dyn :install-time-syspath)
  (use @install-time-syspath/spork/declare-cc)
  (use ./deps/spork/spork/declare-cc))
(dofile "project.janet" :env (jpm-shim-env))
