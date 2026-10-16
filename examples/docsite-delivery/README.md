# MoonDocKit × MoonRelay 文档站交付

独立 native MoonBit 应用，从 Mooncakes 安装 MoonDocKit 0.6.0 与 MoonRelay 0.4.0。`build` 通过 MoonDocKit 的公共库 API 将 Markdown 渲染为完整文档站；`deliver` 通过 MoonRelay 的公共 `push` / `verify` / `pull` API 逐文件交付并校验。

这是一份由 MoonRelay 项目实现的第三方库集成示例，不表示 MoonDocKit 作者已采用、批准或合并了此接入。MoonDocKit 来源：[Estrella-11/moonbit_1](https://github.com/Estrella-11/moonbit_1)，许可证 Apache-2.0。上游源码不复制进本示例，不修改上游项目。

从主仓库运行完整复现（系统需 Python 3、MoonBit native 工具链、SSH；远端需兼容的 MoonRelay 与 Python 3）：

```sh
python3 tools/docsite-case.py --host user@host \
  --remote-parent /absolute/existing/writable/directory \
  --remote-bin /absolute/remote/bin/moonrelay \
  --ssh-config /absolute/ssh_config
```

脚本会在仓库外新建消费者、从注册表安装两项依赖，生成真实文档，向全新的远端子目录发送首个文件，在提交检查点 SIGKILL 消费者，然后重跑相同交付、取回全站，并用 Python 独立比较每个文件在本地、远端及取回后的 SHA-256。结果存放于 output/docsite-UTC时间/。程序只处理本次生成的平面站点文件；通用目录传输请使用 CLI 的 --recursive。

手工体验两个阶段：

```sh
cd /path/to/independent/copy/of/this/example
moon update
moon run . --target native -- build /absolute/markdown-source /absolute/new-site
moon run . --target native -- deliver /absolute/new-site user@host:/absolute/remote-site /absolute/returned-site /absolute/remote/bin/moonrelay /absolute/ssh_config -
```

首次准备须创建远端目录；本地源内容、远端路径与恢复状态在重跑期间须保持一致。最后的 `-` 表示正常执行；传入一个尚不存在的检查点文件路径时，首个文件提交后会暂停 60 秒，供复现驱动终止进程。

本案例验证文件之间的批次恢复和已完成文件复用，不把小型文档站当作大文件中途分块续传测试。站点逐文件可见，不提供整站原子切换、线上托管、自动权限配置或性能优势保证。评分器的站点质量分是 MoonDocKit 内部规则检查，不是赛事评分。
