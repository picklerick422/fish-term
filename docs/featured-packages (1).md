# 特色软件

Harmonybrew 本该只负责包管理，但为了让大家能顺利地在 OpenHarmony 设备上写起代码，我们做了一些“分外之事”。

针对系统环境的诸多限制（如代码签名、平台标识等），我们专门维护了一系列特色软件包，优化了 C/C++、Rust、Python、Node.js、Go 等场景的开发体验。

我们替你填平了这些底层的“坑”，只为让 OpenHarmony 上的操作逻辑能重新对齐你熟悉的 Linux 或 macOS。

## 软件包列表

<table>
  <thead>
    <tr>
      <th>名称</th>
      <th>说明</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td>ohos-sdk</td>
      <td>
        我们将 ohos-sdk 也放在软件仓库中分发，用户安装 ohos-sdk 后即可使用
        clang、llvm-ar 等命令。另外，我们对 ohos-sdk 里面的 lld
        链接器做了简单的脚本封装，默认启用了
        <a
          href="https://atomgit.com/openharmony/third_party_llvm-project/pull/882"
          >链接器签名</a
        >，使得它编出来的程序可以直接在鸿蒙 PC 上运行，无需手动进行代码签名。
      </td>
    </tr>
    <tr>
      <td><div style="min-width: max-content; display: block; white-space: nowrap;">llvm-gcc-compat</div></td>
      <td>
        这个包会生成 cc、gcc、ld 等软链接，全部指向 ohos-sdk 里面的 LLVM
        工具链。这使我们可以更顺利地编译各种开源软件，无需手动指定 CC、CXX
        等环境变量。此做法是模仿 macOS 的做法，macOS 中的 cc、gcc、ld
        等命令也是指向 LLVM 的软链接。
      </td>
    </tr>
    <tr>
      <td>devel-base</td>
      <td>
        类似于 Debian 里面的 build-essential。这个包本身没有任何内容，只是将
        ohos-sdk、llvm-gcc-compat、make、coreutils
        等软件包设置成了级联依赖。只要装了这个包，这些级联依赖就会被装进来，你就拥有了一个较为完善的
        C/C++ 编译环境。命名成 devel-base 是为了避免跟各大 Linux
        发行版里面的同类软件包重名。
      </td>
    </tr>
    <tr>
      <td>uname-is-linux</td>
      <td>
        一个专为鸿蒙 PC 设计的系统标识伪装工具。它通过劫持 libc 中的
        <code>uname()</code> 函数，使应用程序获取的系统标识始终为
        <code>Linux</code>。详细用法请查看
        <a href="https://atomgit.com/Harmonybrew/uname-is-linux">源码仓</a> 里面的
        README 文档。
      </td>
    </tr>
    <tr>
      <td><div style="min-width: max-content; display: block; white-space: nowrap;">ohos-pip-autosign</div></td>
      <td>
        自动对 pip 包里面的 .so 文件进行代码签名。详细用法请查看
        <a href="https://atomgit.com/Harmonybrew/ohos-pip-autosign">源码仓</a> 里面的
        README 文档。
      </td>
    </tr>
  </tbody>
</table>

## 场景演示

### 场景一：编译 C/C++ 程序

在鸿蒙 PC 上编译传统的 C/C++ 开源软件（如 gzip 等）时，通常会面临一个问题：许多开源软件的构建脚本无法识别 OpenHarmony 特有的系统标识，导致配置或编译失败。

为了对齐传统的 Linux 编译体验，Harmonybrew 提供了 uname-is-linux 伪装工具，通过劫持系统调用将系统标识伪装为 Linux，从而让各种开源软件能够无缝完成构建。

在鸿蒙 PC 的 HiShell 环境中编译开源软件 gzip 的完整流程如下：

```sh
# 安装编译工具链和环境伪装工具
brew install -y devel-base uname-is-linux

# HiShell 环境中，TMPDIR 环境变量的默认值是 /storage/Users/currentUser，这个目录承载在 HMDFS 上
# 修改这个环境变量，将其指向一个非 HMDFS 的目录，避免因 HMDFS 文件系统缺陷导致编译失败
export TMPDIR=/data/storage/el2/base/files/tmp
mkdir -p $TMPDIR

# 使用非 HMDFS 目录作为工作目录，避免因 HMDFS 文件系统缺陷导致编译失败
WORKDIR=/data/storage/el2/base/files/work
mkdir -p $WORKDIR
cd $WORKDIR

# gzip 安装目录，安装到 currentUser 下，方便我们使用它
PREFIX=/storage/Users/currentUser/gzip-1.14-ohos-arm64

# 启用全局环境伪装
export LD_PRELOAD=$(brew --prefix)/opt/uname-is-linux/lib/libuname.so

# 编译 gzip
curl -fLO https://ftp.gnu.org/gnu/gzip/gzip-1.14.tar.gz
tar -zxf gzip-1.14.tar.gz
cd gzip-1.14
./configure --prefix=$PREFIX  # 无需再显式指定目标平台（如 `--host=aarch64-linux` 等）
make -j$(nproc)
make install
cd ..

# 编译完成，取消环境伪装
unset LD_PRELOAD

# 验证编出来的 gzip 是否能正常运行
$PREFIX/bin/gzip --help

# 清理临时目录和工作目录
sh -c "rm -rf $TMPDIR/* $WORKDIR/*"
```

### 场景二：编译 Rust 程序

**用法 1：安装 llvm-gcc-compat**

让 llvm-gcc-compat 提供 cc 命令供 rustc 使用。用户无需再额外通过 config.toml 来配置 linker 路径。

在不配置任何 config.toml 的情况下，rustc 默认会调用 cc 命令作为 linker。这个 cc 命令实际上是个软链接，指向了 ohos-sdk 里面的 clang 驱动器。

clang 驱动器在进行链接操作时，调用的是经过我们封装的 ld.lld 脚本，因此最终 rustc 编译出来的二进制都会默认带有代码签名，可直接在鸿蒙 PC 上运行。

```sh
# 安装 rust 和 llvm-gcc-compat（ohos-sdk 会作为 llvm-gcc-compat 的级联依赖被自动引入）
brew install -y rust llvm-gcc-compat

# 创建一个简单的 cargo 工程并将其编译成二进制
cargo new hello_project
cd hello_project
cat > src/main.rs << 'EOF'
fn main() {
    println!("Hello, world!");
}
EOF
cargo build --release

# 测试编译产物是否能正常运行
./target/release/hello_project
```

**用法 2：不安装 llvm-gcc-compat，仅安装 ohos-sdk**

用户需要额外配置 config.toml 指定使用 ohos-sdk 里面的 clang 驱动器作为 linker。

clang 驱动器在进行链接操作时，调用的是经过我们封装的 ld.lld 脚本，因此最终 rustc 编译出来的二进制都会默认带有代码签名，可直接在鸿蒙 PC 上运行。

```sh
# 仅安装 rust 和 ohos-sdk，不安装 llvm-gcc-compat
brew install -y rust ohos-sdk

# 编写一个用户级的 config.toml
mkdir -p ~/.cargo/
cat > ~/.cargo/config.toml << 'EOF'
[target.aarch64-unknown-linux-ohos]
ar = "/storage/Users/currentUser/.harmonybrew/opt/ohos-sdk/native/llvm/bin/llvm-ar"
linker = "/storage/Users/currentUser/.harmonybrew/opt/ohos-sdk/native/llvm/bin/clang"
EOF

# 创建一个简单的 cargo 工程并将其编译成二进制
cargo new hello_project
cd hello_project
cat > src/main.rs << 'EOF'
fn main() {
    println!("Hello, world!");
}
EOF
cargo build --release

# 测试编译产物是否能正常运行
./target/release/hello_project
```

### 场景三：安装 Python 三方库

Harmonybrew 核心 tap 里面提供的 Python 经过了定制化适配，详情请参见 [python@3.14.rb](https://atomgit.com/Harmonybrew/homebrew-core/blob/main/Formula/p/python@3.14.rb)。

由于 Python 官方目前尚未原生支持 aarch64-linux-ohos 平台，为了确保用户能够使用三方库（尤其是包含原生模块的三方库），我们将它的平台三元组硬编码为 aarch64-linux-musl。得益于 OpenHarmony 对 Linux 的兼容性，Python 可以直接复用 Linux 现有的生态，直接下载并运行 aarch64-linux-musl 平台的原生二进制制品（如 numpy、scipy 等）。

该方案在常规 OpenHarmony 设备上均可正常工作，但在鸿蒙 PC 上会面临一个特有的安全限制：当你用 pip 安装这类三方库时，下载到的 so 文件（如 xxx-aarch64-linux-musl\.so）必然不具备鸿蒙 PC 的代码签名，直接加载会导致系统校验失败。

ohos-pip-autosign 便是为了解决这一痛点而生的工具，它能在 pip 安装过程中自动为这些 so 文件补全代码签名。

以 numpy 为例，在鸿蒙 PC 的 HiShell 环境中安装它的完整流程如下：

```sh
# 安装 Python 运行时和自动签名工具
brew install -y python ohos-pip-autosign

# 激活 venv
python3 -m venv .venv
source .venv/bin/activate

# 激活自动签名工具
ohos-pip-autosign activate

# 安装 numpy
pip install numpy

# 编写一段 python 脚本，验证 numpy 是否能正常工作
cat <<EOF > test.py
import numpy as np
arr = np.array([1, 2, 3])
print(arr * 2)
EOF

# 执行脚本
python3 test.py
```

### 场景四：编译 Node.js addon

在 npm 中心仓中，部分三方库包含 C/C++ addon，如 sqlite3、node-sass、bufferutil 等。

由于极少有官方社区会为 OpenHarmony 平台提供预构建产物，导致这些库在鸿蒙设备上无法开箱即用。所幸的是，大多数 addon 都支持在缺少预构建包时自动回退到本地实时构建。

借助 Harmonybrew 提供的开发工具，我们可以在本地轻松完成这一构建过程，让这些库能够在 OpenHarmony 平台上工作。

以在鸿蒙 PC 的 HiShell 环境中实时构建三方库 bufferutil 为例，流程如下：

```sh
# 安装 node 和开发工具（在此场景中 python 也属于开发工具，因为 node-gyp 依赖它）
brew install -y node python devel-base

mkdir test-bufferutil
cd test-bufferutil

# 设置 Node.js 镜像
# node-gyp 会根据这个地址去下载 Node.js 头文件，这里设置成国内源以避免因网络问题下载失败
export npm_package_config_node_gyp_dist_url=https://mirrors.huaweicloud.com/nodejs

# 安装 bufferutil
# 由于 bufferutil 官方未提供 OpenHarmony 平台的预构建包，它会触发实时构建
npm install bufferutil

# 检查实时构建产物是否已经正确生成
# 注意，这个 .node 文件已经默认带有了代码签名（因为是用封装过的 ohos-sdk 工具链进行构建的），
# 所以 Node.js 运行时可以正常加载它
ls -l node_modules/bufferutil/build/Release/bufferutil.node

# 编写一个测试脚本，测试这个库能否正常工作
cat << 'EOF' > test.js
const bufferUtil = require('bufferutil');
const crypto = require('crypto');

const source = crypto.randomBytes(10);
const mask = crypto.randomBytes(4);

console.log(source, mask)
bufferUtil.mask(source, mask, source, 0, source.length);
console.log(source)
bufferUtil.unmask(source, mask);
console.log(source)
EOF

# 执行测试脚本，观察结果
node test.js
```

> 💡 **提示**：该方案仅适用于需要实时构建的场景。对于三方库已经提供了预构建产物但未进行代码签名的场景（如 rollup、rolldown 等），请使用 [ohos-signpost](https://github.com/hqzing/ohos-signpost) 进行处理。具体实践案例可参见 [这篇博客](https://blog.csdn.net/hqzing/article/details/156149868)。

### 场景五：编译 Go 程序

我们在 go 命令行工具的构建管道中打了一个 [自动签名补丁](https://atomgit.com/Harmonybrew/homebrew-core/blob/main/Patches/go/0003-auto-sign-elf.patch)，使 go 在产出 ELF 二进制文件时自动调用 binary-sign-tool 进行代码签名，编译出来的程序无需手动签名即可直接在鸿蒙 PC 上运行。

由于 binary-sign-tool 来自 ohos-sdk，我们让 go 级联依赖了 ohos-sdk，这意味着你只需安装 go 这一个包，ohos-sdk 便会被自动下载并配置好。

在鸿蒙 PC 的 HiShell 环境中编译并运行一个简单的 Go 程序，操作是这样的：

```sh
# 安装 go（ohos-sdk 会作为级联依赖自动引入）
brew install -y go

mkdir go-example
cd go-example

# 编写一个简单的 Go 程序
cat > hello.go << 'EOF'
package main

import "fmt"

func main() {
    fmt.Println("Hello!")
}
EOF

# 编译并运行
go build -o hello hello.go
./hello
```

对于涉及 cgo 的场景，Go 默认会调用 cc 命令作为外部链接器。我们可以安装 llvm-gcc-compat，让它提供 cc 命令（指向 ohos-sdk 中的 clang）。如此一来，cgo 编译可直接开箱即用：

```sh
# 安装 go 和 llvm-gcc-compat（提供 cc 命令供 cgo 使用）
brew install -y go llvm-gcc-compat

mkdir cgo-example
cd cgo-example

# 编写一个 cgo 程序
cat > hello_cgo.go << 'EOF'
package main

/*
#include <stdio.h>
void hello() { printf("%s\n", "Hello from cgo!"); fflush(stdout); }
*/
import "C"

func main() {
    C.hello()
}
EOF

# 编译并运行
CGO_ENABLED=1 go build -o hello_cgo hello_cgo.go
./hello_cgo
```
