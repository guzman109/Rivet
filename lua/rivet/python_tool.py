"""Resolve a task runner before making application import paths visible."""

import importlib
import importlib.util
import os
import sys
import types

runner, root, source = sys.argv[1:4]
arguments = sys.argv[4:]

# -E -P excludes PYTHONPATH and the working directory during runner discovery,
# while retaining packages installed in the selected environment and user site.
module = importlib.import_module(runner)
name = runner + ".__main__" if hasattr(module, "__path__") else runner
spec = importlib.util.find_spec(name)
if spec is None or spec.loader is None or not hasattr(spec.loader, "get_code"):
    raise ImportError("The selected Python task runner has no executable module: " + runner)
code = spec.loader.get_code(name)
if code is None:
    raise ImportError("The selected Python task runner has no executable code: " + runner)

paths = ([source] if source else []) + [root]
paths.extend(path for path in os.environ.get("PYTHONPATH", "").split(os.pathsep) if path)
sys.path[:0] = list(dict.fromkeys(os.path.abspath(path) for path in paths))
sys.argv[:] = [spec.origin or name] + arguments
main = types.ModuleType("__main__")
main.__dict__.update(
    __file__=spec.origin,
    __cached__=spec.cached,
    __loader__=spec.loader,
    __package__=spec.parent,
    __spec__=spec,
)
sys.modules["__main__"] = main
exec(code, main.__dict__)
