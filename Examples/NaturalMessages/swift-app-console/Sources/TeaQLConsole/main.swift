import TeaQLCore
import GeneratedTeaQL

var runtime = TeaQLRuntime()
try runtime.install(GeneratedRuntimeModule.module)
print("checker-natural-message-service TeaQL console ready (\(runtime.entities.count) entities)")
