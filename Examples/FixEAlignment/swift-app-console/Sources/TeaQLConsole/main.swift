import TeaQLCore
import GeneratedTeaQL

var runtime = TeaQLRuntime()
try runtime.install(GeneratedRuntimeModule.module)
print("checker-fix-advanced TeaQL console ready (\(runtime.entities.count) entities)")
