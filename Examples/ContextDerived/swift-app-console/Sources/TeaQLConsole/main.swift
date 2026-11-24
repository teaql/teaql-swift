import TeaQLCore
import GeneratedTeaQL

var runtime = TeaQLRuntime()
try runtime.install(GeneratedRuntimeModule.module)
print("context-fix-service TeaQL console ready (\(runtime.entities.count) entities)")
