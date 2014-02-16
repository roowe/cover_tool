cover_tool
==========

wrap erlang cover module

# What
这是简单的封装cover的使用，自动编译需要分析的App所有模块，并定时analyze，看覆盖程度。我的使用场景就是，内网服务器在跑，测试在测试或者客户端开发人员在开发，一段时间之后，我就能大概知道代码覆盖程度了。这是填没有单元测试，但是又想知道大多数情况的代码覆盖情况的坑。

# How
配置下下面的参数
```erlang
{generate_dir, "/tmp/cover_generate_dir"},
{analyze_app, server},
{analyze_interval, 1200}
```
然后在启动App前，启动cover_tool
```erlang
application:start(cover_tool)
```
