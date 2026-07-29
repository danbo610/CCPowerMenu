# CCPowerMenu roothide / iOS 16 适配与修复工作总结

对上游 [MTACS/CCPowerMenu](https://github.com/MTACS/CCPowerMenu) 1.0.1 在 **roothide 越狱 + iOS 16.3.1** 上的移植、除错与功能改造记录。分支 `fix/roothide-ios16`,版本 1.0.1 → 1.0.13,仓库为 [danbo610/CCPowerMenu](https://github.com/danbo610/CCPowerMenu)(上游保留为 `upstream` remote)。

目标设备:iPhone 12 Pro(iPhone13,3),iOS 16.3.1(20D67),roothide(Dopamine 系)+ ellekit + CCSupport。

---

## 0. 一句话结论

原版在这台设备上**完全不可用**,而且有两处会把系统搞坏:菜单永远是空的;模块代码一旦执行就会劫持 SpringBoard 的 `NSUserDefaults` 单例导致崩溃;Respring 菜单项会杀掉渲染服务器造成**永久黑屏、只能强制重启并重新越狱**。这三个问题都已修复并在真机验证,另外补了误点确认框,并把交互改成「单击展开菜单 / 长按直接注销」。

| # | 问题 | 性质 | 状态 |
|---|---|---|---|
| 1 | 菜单永远为空 | 逻辑缺陷 | 已修,已验证 |
| 2 | 劫持宿主 `NSUserDefaults` 单例 → SpringBoard 崩溃 | 严重缺陷 | 已修,已验证 |
| 3 | Respring = `killall backboardd` → 永久黑屏、掉越狱 | **致命** | 已修,已实测 |
| 4 | Reboot Userspace 在 roothide 上静默失效 | 越狱适配 | 已修,提权已验证 |
| 5 | 无误点保护 | 功能缺失 | 已加,已验证 |
| 6 | 长按才出菜单,不符合使用习惯 | 交互改造 | 已改,已验证 |
| 7 | 菜单展开后拖动不跟手、松手不执行且高亮卡住 | 交互缺陷 | 已修,已验证 |
| 8 | 面板高度写死屏高 80%,大片空白 | 布局缺陷 | 已修,已验证 |
| 9 | 头部只有一句无用副标题 | 功能增强 | 已加设备状态栏 |
| 10 | 菜单全英文 | 本地化 | 已中文化 |
| 11 | 想在菜单里开关 LetMeBlock | 功能增强 | 已接入 Choicy,状态双向可见 |
| 12 | 设置页开关与菜单实际显示不一致 | 逻辑分叉 | 已统一 |
| 13 | 点菜单项后菜单先收回,确认框才弹 | 交互 | 已改为叠加在展开的菜单上 |
| 14 | 磁贴图标是个停住的菊花,Resources 里找不到 | 观感 | 已换成自绘的同款图标 |

---

## 1. 编译链路

本机是 Linux,没有 iOS SDK。项目文档 `../PHONE_ACCESS.md` 建议用 GitHub Actions 云编译,但实测**跳板 Mac 上已有现成的 `~/theos-roothide`**,直接在 Mac 上编更快(几十秒一轮),整个过程没用到 Actions。

```bash
ssh -F ~/.ssh/config_phone mac '
  export THEOS=$HOME/theos-roothide
  cd ~/build-ccpowermenu/CCPowerMenu
  make clean; rm -rf packages
  make package THEOS_PACKAGE_SCHEME=roothide FINALPACKAGE=1 DEBUG=0 \
       SYSROOT=$THEOS/sdks/iPhoneOS16.5.sdk'
```

关键点:

- **两处 Makefile 值必须在命令行覆盖,没有改动仓库文件**:
  - `SYSROOT` 写死了 `iPhoneOS14.2.sdk`,Mac 上只有 `iPhoneOS16.5.sdk`;
  - `DEBUG = 1` 会产出 `1.0.1+debug` 的调试包,用 `DEBUG=0` 覆盖。
  - Make 的命令行变量优先级高于 Makefile 内的 `=` 赋值,所以覆盖有效,并会自动传递给 `SUBPROJECTS`(`userspace-reboot`)。
- Mac 上**没有 `dpkg-deb`**,Theos 自动回落到 `vendor/dm.pl` 打包,产物正常。
- 产出 `iphoneos-arm64e`(roothide 的架构标签),二进制是 arm64 + arm64e 双架构 fat,由 Apple 原生 clang 编译——符合 `PHONE_ACCESS.md` 里「注入 arm64e 进程必须用原生 clang」那条铁律。
- 装机:`scp` 到手机 `/var/root/` 后 `dpkg -i`,再 `sbreload`。

---

## 2. 问题一:菜单永远是空的

### 现象
长按图标能弹出 "Power Options" 窗口,但里面一个菜单项都没有。

### 定位
用 Frida attach SpringBoard 做只读探针(读偏好设置 + 枚举实例):

```
prefs[inDomain] itemOrder  = nil
prefs[inDomain] itemStates = nil
_menuItems = ()                       ← 实例里菜单项数组是空的
```

`/var/mobile/Library/Preferences/com.mtac.ccpowermenu.plist` 拉回本机用 `plistlib` 解析,里面只有系统写的三个键(`CCUIUserInvocationCount` 等),**没有插件自己的键**。

对照源码 `CCPowerMenuViewController.xm`:

```objc
NSArray *itemOrder = [preferences objectForKey:@"itemOrder"];
for (NSString *identifier in itemOrder) { [self addActionForIdentifier:identifier]; }
```

再看设置页 `CCPowerMenuListController.m` 的 `updateList`:默认的 5 个条目只在**内存里**构造给表格显示,从不落盘;真正写盘只发生在拖动排序(写 `itemOrder`)和拨开关(只写 `itemStates`)。所以只要用户没手动拖过行,`itemOrder` 恒为 nil,循环零次。

### 还有第二层
挂 trace 观察生命周期,发现 `loadItems` 的唯一自动触发点 `viewWillTransitionToSize:withTransitionCoordinator:` **在 iOS 16 上从头到尾没有被调用过**,下拉 CC 时只有 `viewWillAppear:` 触发。也就是说即使偏好设置里有值,菜单也不会被填充。

### 修复
- `loadItems` 读不到 `itemOrder` 时回落到与设置页一致的默认顺序;
- `addActionForIdentifier:` 把「`itemStates` 里没有该键」视为启用(原来 `nil` 会被当成 `NO`);
- 设置页首次进入时把默认值**持久化**,让两边状态一致;
- `viewDidLoad` 和 `viewWillAppear:` 都调用 `loadItems`;
- 顺手修了 `HEIGHT` 宏的笔误(`bounds.size.width` → `.height`)。

### 验证
```
instance 0x...  actionsCount = 5
  Respring / Safe Mode / Reboot Userspace / Restart / Shutdown
```

---

## 3. 问题二:劫持宿主的 `NSUserDefaults` 单例(SpringBoard 崩溃)

### 现象
在我用 Frida 强行调用 `loadItems` 验证数据通路之后,用户下拉控制中心时 SpringBoard 崩溃。

> **责任说明**:这次崩溃是我触发的。这段代码在此之前从未执行过(因为 `itemOrder` 是 nil 且触发时机不对),我为验证而调用了两次 `loadItems`,我自己的探针脚本也直接调用过 `initWithSuiteName:`。**我本该先看清那个宏再动手。**

### 定位:静态证据
设备上没有 CrashReporter 目录(roothide 关掉了崩溃日志),拿不到 `.ips`。改从编译产物入手——注意 **shipping 二进制被 strip 了,要看未 strip 的 `.o`**:

```bash
otool -tV .theos/obj/arm64/CCPowerMenuViewController.xm.*.o | sed -n '/loadItems\]:/,/addActionForIdentifier:\]:/p'
```

```
bl _objc_msgSend$standardUserDefaults      ← 取的是 SpringBoard 的共享单例
bl _objc_retainAutoreleasedReturnValue
bl "_objc_msgSend$initWithSuiteName:"      ← 对这个活着的单例再调一次 init
bl "_objc_msgSend$objectForKey:"
```

问题出在头文件里这个宏:

```objc
#define preferences [[NSUserDefaults standardUserDefaults] initWithSuiteName:@"com.mtac.ccpowermenu"]
```

它不是「创建一个新的 suite defaults」,而是**对宿主进程正在使用的 `standardUserDefaults` 单例重新 `init`**。

### 定位:对照实验
不敢在 SpringBoard 上验证(已经弄崩一次),改在**无关进程 Sileo** 里做对照实验:

```
BEFORE  singleton = 0x2827f88d0   dictionaryRepresentation count = 81
        probeKey "touch_trace_enabled" = 0
AFTER   returned obj = 0x2827f88d0   (same object? true)
        standardUserDefaults() = 0x2827f88d0  (still the same singleton? true)
        dictionaryRepresentation count = 34      ← 宿主自己的偏好设置没了
        probeKey "touch_trace_enabled" = null    ← 原本有值的键读不到了
        ccpowermenu itemOrder = (respring, ...)  ← 搜索域被换成了插件的
```

同一个对象指针、键数 81 → 34、原有键全部读成 nil。在 SpringBoard 里发生这事 = 它读自己的偏好设置时必崩。

宏在 `loadItems` 里 1 次、`addActionForIdentifier:` 里每项 1 次,一次刷新就是 6 次。

### 修复
```objc
#define preferences [NSUserDefaults standardUserDefaults]
// 所有读取改为 objectForKey:@"..." inDomain:domain —— 该私有 API 不触碰单例状态
```

### 验证
- 新二进制中 `initWithSuiteName` 引用数 = **0**;
- 运行时 SpringBoard 的 `standardUserDefaults` 键数 = **277**(健康值;被劫持时是几十)。

---

## 4. 问题三:Respring 造成永久黑屏 + 掉越狱(最严重)

### 现象
用户点击菜单里的 Respring → SpringBoard 注销 → **黑屏再也没有恢复,SSH 也断了** → 只能强制重启手机并重新越狱。

### 原版代码
```objc
const char* args[] = {"killall", "backboardd", NULL};
posix_spawn(&pid, ROOT_PATH("/usr/bin/killall"), NULL, NULL, (char* const*)args, NULL);
```

杀的是 **backboardd(渲染 / 显示服务器)**,不是 SpringBoard。这不是 respring,是把整个显示栈掀了。

### 定位:entitlement 证据
关键在于 **backboardd 被杀后要能重新拉起来是需要 entitlement 的**。越狱自带的 `sbreload`(整个过程中我们用了很多次,每次都正常)带着:

```bash
ldid -e /usr/bin/sbreload
```
```
com.apple.appletv.pbs.allow-relaunch-backboardd   ← 就是它
com.apple.appletv.pbs.allow-relaunch
com.apple.frontboard.shutdown
com.apple.frontboard.launchapplications
com.apple.private.security.no-sandbox
```
而且 `strings` 显示它链接 SpringBoardServices、通过 XPC 与 launchd 握手(`_xpc_pipe_routine`)。

插件这边:从 SpringBoard 里 `posix_spawn` 一个**普通的 `/usr/bin/killall`**,身份是 `mobile`,**一个 entitlement 都没有**。显示服务器被杀死而没有任何东西被允许把它拉回来 → 永久黑屏 → 强制重启 → roothide 上等于掉越狱。(SSH 也断是因为会话走 Mac 的 usbmux 转发,设备 UI 栈塌掉后整条链路被拖垮。)

### 修复
用 Frida 只读枚举确认 `FBSystemService` 在 iOS 16.3 上有 `exitAndRelaunch:`(插件本来就在用 `FBSystemService` 做重启/关机):

```objc
FBSystemService *systemService = [%c(FBSystemService) sharedInstance];
[systemService exitAndRelaunch:YES];
```

只让 SpringBoard 退出并由 launchd 拉起,**完全不碰 backboardd**,不需要 root、不需要 entitlement、不需要辅助程序。

### 验证(实测,SSH 全程守着做保底)
```
backboardd alive BEFORE
→ exitAndRelaunch:YES
SpringBoard back after ~3s
backboardd alive AFTER (never touched)
uptime 0:19   ← 没重启,越狱没掉
```

---

## 5. 问题四:Reboot Userspace 在 roothide 上静默失效

### 定位
辅助程序 `userspace-reboot` 原本靠 `setuid(0)` 提权,失败就 `exit(1)`。但:

```bash
mount | grep /private/var
/dev/disk1s2 on /private/var (apfs, local, nodev, nosuid, journaled, noatime, protect)
```

roothide 的 jbroot 在 `/var/containers/Bundle/Application/.jbroot-*/` 下,即 `/private/var` 分区,**`nosuid` 挂载 → setuid 位被内核忽略**,程序以 mobile 身份运行,自己退出了。这正是 roothide 提供 `libjailbreak.dylib` 提权 API 的原因。

### 修复
```objc
// setuid 失败后回落到向 jailbreakd 要 root
void *handle = dlopen(ROOT_PATH("/usr/lib/libjailbreak.dylib"), RTLD_NOW);
int (*stealUcred)(uint64_t, uint64_t *) = dlsym(handle, "jbclient_root_steal_ucred");
uint64_t originalUcred = 0;
stealUcred(0, &originalUcred);
```

并加了 `--check` 参数:只报告能否拿到 root,**不触发任何重启**,以后排查不用拿真机冒险。

### 验证
```bash
su mobile -c '/usr/libexec/userspace-reboot --check'
uid before=501 after=0 -> root acquired
```

### 顺带查实的两件事
- `/usr/bin/launchctl` 确实带 `com.apple.private.xpc.launchd.userspace-reboot`,spawn 那一步本来就没问题;
- **用户态重启不会掉越狱**:Dopamine app 自己就有 "Reboot Userspace" 菜单(二进制里有 `Menu_Reboot_Userspace_Title` / `rebootUserspace`),这是越狱支持的一等公民操作。

---

## 6. 新增:误点确认框

每个动作都不可逆,原版没有任何确认。参照 CCPower 的做法补上。

**实现要点**:控制中心的模块没有可以 `present` 的 view controller,所以自建一个 `UIWindow`,层级 `UIWindowLevelAlert + 1`。iOS 16 上需要 window scene,Frida 只读探针确认 SpringBoard 恰好暴露一个 foreground-active 的 `SBWindowScene`:

```
connectedScenes count = 1
  [0] SBWindowScene  activationState=0  role=UIWindowSceneSessionRoleApplication
```

**Fail closed**:取不到 scene 就直接返回,动作不执行。这个菜单里每一项都不可逆,失败方向必须是「什么都不做」。

文案与按钮为中文(取消 / 注销 / 关机 …),确认按钮用 `UIAlertActionStyleDestructive`。

> 小坑:中文字面量以 **UTF-16 存在 `__ustring` 段**,`strings` 抓不到 CJK,验证要用 Python 按 `utf-16-le` 匹配:
> ```python
> u16 = '确定要注销吗?'.encode('utf-16-le');  print(u16 in open(binary,'rb').read())
> ```

---

## 7. 交互改造:单击展开菜单 / 长按直接注销

需求:与 CCPower、PowerSelector 一致——单击出菜单;长按直接 respring(最快捷的注销方式)。

这部分**迭代了四轮**,每轮都靠 trace 定位,记录如下。

### 第一轮(1.0.3):接管手势
只读探针查明两件事:

```
gesture[0] UILongPressGestureRecognizer  minimumPressDuration=0
   _targets = (action=_handlePressGesture:, target=<CCPowerMenuViewController>)   ← 目标是我们自己的类

CCUIContentModuleContainerViewController(parentViewController)有:
   - expandModule
   - isExpanded
```

所以不必改成 UIAlertController action sheet,**原生菜单可以保留**,只覆写 `_handlePressGesture:`:Began 起 0.5 秒计时器,到点 → respring;Ended 且计时器没触发 → `[container expandModule]`。

### 第二轮(1.0.4):长按去掉确认
按用户要求,长按路径直接执行,不弹确认;菜单项仍保留确认。拆出 `respringNow` 供两条路径共用。

### 第三轮(1.0.5):菜单项点不动了
现象:单击能出菜单,但**菜单项点了没反应**;手指多停一会儿反而直接注销了。

挂 trace 抓到:

```
# 单击图标
press Began/Ended  self.expanded=false  container.isExpanded=false
openMenu → expandModule → will/didTransitionToExpandedContentMode:YES     ✓ 菜单展开

# 点菜单项 —— 没反应
press Began  self.expanded=FALSE  container.isExpanded=TRUE      ← 判断依据错了
press Ended
openMenu → expandModule          ← 又「展开」了一次已展开的菜单

# 手指停留超过 0.5 秒 —— 直接注销
press Began  →  respringNow
```

`setExpanded:` **全程没有被调用过**。原因:在原生流程里是 super 的 `_handlePressGesture:` 负责置位 `_expanded`,而我们绕过了 super,所以 `self.expanded` 恒为 false,守卫永不成立,菜单项的触摸全被吞掉,而且停留超时还会误触发注销。

修复:改用容器的 `isExpanded`(trace 显示它是可信的),并在计时器触发前复查一次。

### 第四轮(1.0.6):长按被 CC 抢走
现象:菜单项修好了,但长按退化成原生行为(弹菜单),不再注销。

trace:

```
press Began   containerExpanded=false      ← 我们排了 0.5s 计时器
willTransitionToExpandedContentMode:YES    ← 菜单自己展开了,没有 openMenu、没有 expandModule
press Changed containerExpanded=true
```

枚举容器自身的手势,真相大白:

```
container gestures = 6
   _UITouchDurationObservingGestureRecognizer  target=<_UIControlCenterClickInteractionDriver>
   _UITouchDurationObservingGestureRecognizer  target=<_UIControlCenterClickInteractionDriver>
   _UISimplePressGestureRecognizer             target=<_UIPressClickInteractionDriver>
   ...
```

**Control Center 有一条完全独立的展开通道**(容器上的 UIKit click interaction),和我们的手势并行运行,在 0.5 秒之前就把菜单展开了,于是第三轮加的复查判定「已展开」而放弃注销。

修复:用 `shouldBeginTransitionToExpandedContentModule`(这是我们自己类里的方法,CC 展开前会征询)当闸门——

```objc
- (BOOL)shouldBeginTransitionToExpandedContentModule {
    if (self.allowExpansion) return YES;   // openMenu 自己要展开
    return !self.pressInProgress;          // 手指按在图标上期间,这次按压属于注销快捷方式
}
```

这个设计**刻意保底**:万一 CC 那条路径不征询这道门,结果也只是退回上一版行为,不会把已修好的单击和菜单项弄坏。

三步实测通过:长按直接注销 / 单击展开菜单 / 菜单项弹确认框。

---

## 8. 与 CCPower、PowerSelector 的对比审查

用户机上另装了 CCPower(`netskao.ccpower-rootless`)和 PowerSelector(`com.ichitaso.powerselector11`)。把两者的二进制拉回本机做静态分析(`strings` + 手机上 `otool -tV` 反汇编 + `nm -u` 导入表)。

| | CCPowerMenu(原版) | CCPowerMenu(现在) | PowerSelector | CCPower |
|---|---|---|---|---|
| Respring | `killall backboardd` ❌ | `exitAndRelaunch:` | **`sbreload`** 为主;另有 `killall backboardd` 作可选项,由偏好开关切换 | 无命令字符串,纯 API |
| Safe Mode | `killall -SEGV SpringBoard` | 同左(未改) | **完全相同** | — |
| 用户态重启 | `setuid(0)`(静默失效) | libjailbreak 提权 + `launchctl reboot userspace` | `psusreboot` helper | `CCPowerLdrestart` helper |
| Restart | `shutdownAndReboot:YES` | 同左 | **相同** | **相同** |
| Shutdown | `shutdownAndReboot:NO` | 同左 | **相同** | **相同** |
| 路径解析 | `jbroot()` | `jbroot()` | `access()` 在 `/usr/bin` 与 `/var/jb/usr/bin` 间二选一 | — |
| 误点确认 | 无 ❌ | 有 | 有 | 有(UIAlertController) |
| 菜单形态 | 原生展开菜单 | 原生展开菜单 | UIAlertController | UIAlertController |

审查结论:

1. **PowerSelector 也有 `killall backboardd` 那条路**(反汇编 `0x7888` 处是一个偏好字节的二选一),开了那个「深度注销」开关会踩到同样的坑。
2. **我们的用户态重启比 PowerSelector 更适配这台机器**:它的 `psusreboot` 用 dlsym 找 `jb_oneshot_entitle_now` / `jb_oneshot_fix_setuid_now`,而本机 libjailbreak **没有导出这两个符号**(`nm -gU` 验证);我们用的 `jbclient_root_steal_ucred` 是导出的且实测有效。
3. **路径解析我们更正确**:PowerSelector 用 `access()` 在两条固定路径里挑,而 roothide 的 jbroot 是**随机化**的(用户重新越狱后从 `.jbroot-DCC8FA4F62577EEA` 变成了 `.jbroot-26CF0E5EE1A7738C`),`/var/jb -> /` 只是兼容软链;`jbroot()` 才是正规解法。
4. Safe Mode 与 PowerSelector 完全一致,无需改动。
5. PowerSelector 另有 `ldrestart`、`uicache -a`、重启 CommCenter、uptime 显示等功能,不属于电源菜单必需项,未移植。

---

## 9. 设备状态栏与数据口径

把头部那句无用的 "Scroll down for more options" 换成实时设备状态,每次模块出现时刷新:

```
[电池] 健康度:112.90%,循环次数:334
[存储] 总:255.9G,剩余:40.1G,可用:85.2G
[运存] 总:6.0G,可用:2.9G,使用率:51%
[运行时间] 0天4小时1分
```

| 项 | 来源 |
|---|---|
| 电池健康 / 循环次数 | IOKit `AppleSmartBattery`:`NominalChargeCapacity ÷ DesignCapacity`、`CycleCount` |
| 运行时间 | `sysctl KERN_BOOTTIME` 与当前时间之差 |
| 存储 | `statfs()` 的 `f_blocks` / `f_bavail`,外加 `NSURLVolumeAvailableCapacityForImportantUsageKey` |
| 运存 | `NSProcessInfo.physicalMemory` + `host_statistics64` |

每一项**独立降级**:取不到就少一行,不会整块空掉。IOKit 的四个函数是手写声明(不引头文件),`.xm` 按 Objective-C++ 编译,所以必须包 `extern "C"` —— 第一次构建就栽在符号修饰上。

### 9.1 存储的两个口径差了 45GB

一开始只显示一个"可用",用的是 `NSURLVolumeAvailableCapacityForImportantUsageKey`,报 85GB,而 CCPower 和 `df -h` 都是 37GB。差异有两层:

1. **进制**:总容量的字节数与 df **完全一致**(255,881,465,856 B),只是我按 `/1e9` 印成 256,df 按 `/1024³` 印成 238 却仍标 "GB"。同一个数,两种进制。
2. **语义**:那个键返回的是"系统认为**能腾出来**的空间",把可清除缓存、可卸载 App 内容、可从 iCloud 重新下载的文件都算了进去;df 用的是 `statfs` 的 `f_bavail`,即**裸的文件系统空闲块**。

最终两个都显示:`剩余` = statfs(与 df 一致),`可用` = 含可回收。运存同理——只算 `free_count` 的话使用率会恒定在 97%(iOS 本就把空闲页压得极低),所以"可用"计入内核可回收页(`free + inactive + purgeable`,`free_count` 已含 speculative,未重复计)。

---

## 10. vibrancy 材质:颜色在这里是无效的

控制中心整块套在 **vibrancy 效果**里,它把绘制内容压成**亮度蒙版**再由材质着色。三个现象都是同一个原因:

1. **emoji 变成灰色方块**。🔋💾🧠⏱ 的颜色信息在渲染阶段被丢弃,只剩轮廓剪影。正确做法是用 **SF Symbols 模板图**(`NSTextAttachment` + `UIImageRenderingModeAlwaysTemplate`)——菜单行的图标本来就是这么画的,所以它们看起来干净。
2. **把文字设成纯白毫无变化**。实测:白色、灰色、semibold 三种渲染出来一样暗。
3. **行标题亮、行副标题暗**,而字号差别并不足以解释。因为它们分属不同风格的 vibrancy 层:标题在 **label(主要)**,副标题和头部状态栏在 **secondaryLabel(次要)**。

结论:**在同一 vibrancy 层内无法提高亮度**。要和行标题一样亮,只能把标签换到 label 风格的效果视图里(副作用是同层其它元素一起变亮),这一步没做,维持现状。

---

## 11. 首次展开的布局错位

现象很具体:**respring 后的第一次展开**头部空一截、最后一行被切;之后每次都正常。

用一次**"把诊断值印进界面"**的构建拿到了确切数值(不注入 SpringBoard):

```
[调试] label=Y f=13 sep=165 est=130 rep=425
```

配合截图按面板宽度换算,真相是:

- 父类的头部高度**基本是固定的 ≈158pt**,不会因为只放 4 行就收缩(所以 4 行时空一截);
- 我上报的面板高度取 `MAX(查询时分隔线位置, 自己的估算)`;
- 首次展开时分隔线**还没落位**,估算值(4 行 ≈121pt)小于父类实际用的 158pt → 少报约 37pt → 最后一行被挤出去;
- 第二次起分隔线已停在 158,`MAX` 自然取对。

中途还出现过"多加一行调试信息反而正常"的假象 —— 那不是调试功能修好了什么,**只是 5 行文本把估算垫到了 165pt,恰好越过父类的 158pt 阈值**。

**修法**:展开完成后把分隔线的真实位置记进偏好设置(`headerHeight`),之后每次计算取 `MAX(当前分隔线, 内容估算, 学到的真实高度)`。这样 respring 后的首次展开用的是**上一次的事实**而非估算;按设备学习,不写死数字,以后增删菜单项自动跟随。另外若类本身暴露 `_headerHeight` 之类方法(`respondsToSelector:` 探测),优先用它。

顺带修掉两个相关问题:
- **字体"大变小"跳动**:`adjustsFontSizeToFitWidth` 在多行标签上会先按原字号排版再整体缩放,过程肉眼可见。关掉它,固定 13pt。
- **父类会在布局时把标签换回自己的字号**:覆写 `viewDidLayoutSubviews`,发现字号不对就重贴富文本(styling 与强制布局拆开,避免递归)。

---

## 12. 一次由探针造成的事故(第二次)

排查面板高度时,我在 Frida 脚本里**直接在 JS 线程上调用了 UIKit 布局方法**:

```js
inst._menuItemsHeightForWidth_(312)
inst.preferredExpandedContentHeightWithWidth_(312)
```

UIKit 不是线程安全的,这些方法要取 CoreAnimation / UIView 的布局锁。日志正好停在这一句之前的最后一行输出。SpringBoard 被拖死后由看门狗杀掉,重启后**桌面图标全部不显示**,用户只能重启手机并重新越狱。此外 `ObjC.choose()` 扫堆时会**暂停进程所有线程**,在 SpringBoard 里本身就是重操作。

第一次事故(§3)是对共享单例调 `init`,这一次是跨线程碰 UIKit —— 两次都是**探针本身破坏了宿主**。此后本项目的三个新需求(高度自适应、拖动跟手、状态栏)**全部在插件自己的代码里完成,零注入**:introspection 用 `respondsToSelector:` 写在插件里(天然跑在主线程),诊断值直接印进界面。

---

## 13. 新增:LetMeBlock 开关(与 Choicy 共享状态)

需求:菜单里加一项开关 LetMeBlock(让 mDNSResponder 认 `/etc/hosts` 的插件),标题随状态翻转,并且**在 Choicy 里也能看到相同状态**。

### 13.1 机制确认(读 Choicy 源码)

三条事实决定了方案可行:

1. **`globalDeniedTweaks` 无条件作用于所有进程**,守护进程不例外(`Tweak.c`:全局禁用列表在所有分支之前判定,不区分 App 与 daemon);
2. 列表里存的是**去掉 `.dylib` 后缀**的名字(`Tweak.c` 里把末尾 6 个字符截掉,再用 `xpc_array_contains_string` 比对);设备上现有的 `['FuckWeChatAds', 'NoSettingsBadge']` 正是 Choicy UI 自己写的,可作格式对照;
3. Choicy 自己的注入过滤器是 `Filter: Bundles: [com.apple.Security]` —— 几乎所有进程都链接 Security.framework,等于**注入到所有进程**,所以它确实在 mDNSResponder 里,有能力拦住 LetMeBlock(后者的过滤器是 `Executables: [mDNSResponder, mDNSResponderHelper]`)。

### 13.2 必须用目标自己的写入方式

第一版我用了 `NSUserDefaults` 的 `setObject:forKey:inDomain:`。**这是错的**,查源码才发现 Choicy 根本不走 CFPreferences:

```objc
void writePreferences(NSMutableDictionary *mutablePrefs) {
    [mutablePrefs writeToFile:kChoicyPrefsPlistPath atomically:YES];   // 直接写文件
    [CHPListController sendChoicyPrefsPostNotification];               // 再发 Darwin 通知
}
```

混用两种机制有实际危害:cfprefsd 缓存**整个域**,我的写入可能把用户在 Choicy 里改的其它设置覆盖回旧值;反过来 Choicy 直接写文件后,我这边也可能读到过期数据。

改成与它逐项对齐:

| | Choicy 设置页 | CCPowerMenu |
|---|---|---|
| 文件 | `JBROOT_PATH(/var/mobile/Library/Preferences/com.opa334.choicyprefs.plist)` | 同一路径(inode 实测相同:`228142908`) |
| 键 / 值 | `globalDeniedTweaks`,dylib 名不带后缀 | 同 |
| 写法 | 整份读出 → 改 → `writeToFile:atomically:` | 同 |
| 通知 | `com.opa334.choicyprefs/ReloadPrefs` | 同 |

整份读出再写回,`preferenceVersion` / `appSettings` / `daemonSettings` 原样保留。实测双向可见:菜单里切换后,Choicy 的「全局插件配置」开关同步变化。

### 13.3 让改动即刻生效

Choicy **只在进程启动时**判定是否加载某个 dylib,所以改完配置还得重启 `mDNSResponder` 和 `mDNSResponderHelper`(launchd 立刻拉回)。这需要 root,于是把原来的 `userspace-reboot` 辅助程序一般化并改名为 **`ccpowermenu-helper`**,支持 `userspace-reboot` / `restart-mdns` / `--check` 三个子命令,提权逻辑只保留一份。dpkg 升级会自动删除旧的 `/usr/libexec/userspace-reboot`。

### 13.4 加新菜单项要处理迁移

`itemOrder` 一旦落盘就固定了。只改默认值的话,**老用户永远看不到新项**。所以模块和设置页都加了同一段合并逻辑:读到的顺序里缺哪个默认项,就按它在默认顺序里的位置插回去。设置页的行数也从写死的 5 改成跟随实际条目数。

---

## 14. 两处收尾修正

### 14.1 设置页的开关和菜单说的不是一回事

新加的 LetMeBlock 在菜单里正常显示,但设置页里它的开关是**关**的。两边对"`itemStates` 里没有这个键"给了相反解释:

| | 读法 | 结论 |
|---|---|---|
| 模块 | `if (!state \|\| [state boolValue] == YES)` | 缺失 = **启用** |
| 设置页 | `[[self.itemStates objectForKey:item] boolValue]` | nil 的 `boolValue` = **NO** |

统一成模块那条规则:设置页读到缺失的条目就补 `@YES` 并落盘,此后两边从同一份状态出发。位置本来就一致,是因为 `itemOrder` 的合并逻辑上一版已经加过——这次等于把 `itemStates` 也补齐。落盘时机是**打开一次设置页**。

### 14.2 让确认框叠在展开的菜单上

原先点菜单项,菜单会先收回、确认框才出现。收菜单的**不是我们**:CC 在 `_handleActionTapped:` 里先收再执行动作,所以确认框永远出现在一个已经关掉的菜单前面。

我们本来就覆写了这个方法(用来记标志位防重复执行),现在遇到菜单行**不再调 super**,自己执行动作,CC 也就没机会收菜单。同时去掉了 `performActionForMenuItemView:` 里那句主动 `dismissExpandedModuleAnimated:`。

副作用都是正向的:点「取消」后菜单原样还在;LetMeBlock 这类切换执行完 `loadItems` 就地刷新,**标题当场翻转而菜单不关**。

---

## 15. 磁贴图标:那个「转圈」其实是个停住的菊花

Resources 目录里找不到磁贴图标,因为**它根本不是图片**:

```objc
self.spinnerIndicatorView = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
self.spinnerIndicatorView.hidesWhenStopped = NO;   // 停着也画出来
[self.view addSubview:self.spinnerIndicatorView];  // 直接贴到磁贴上
```

上游拿一个**从没 `startAnimating` 过的 `UIActivityIndicatorView`** 当图标使,靠 `hidesWhenStopped = NO` 让它停住仍然渲染。模块自始至终没有设过 `glyphImage`。

改成 PowerSelector 同款(手机轮廓 + 内部一圈渐变辐条)时有个取舍:那是别人的美术资源,**不适合提交进公开仓库**。所以用 Core Graphics 自绘了一个:圆角手机轮廓 + 顶部听筒槽 + 12 根 alpha 从 0.25 渐变到 1.0 的圆头辐条,尺寸沿用 37×37,以 `UIImageRenderingModeAlwaysTemplate` 输出——与菜单行图标同一套画法,正好吃 vibrancy 那套亮度映射(见 §10)。

同时留了加载钩子:`Resources/` 里若存在 `Icon@2x/@3x.png` 就优先使用,想换成任何现成图片都不必改代码。几何参数(`kGlyphBodyWidth` / `kGlyphSpokeInnerRadius` / `kGlyphSpokeCount` 等)都是常量。

---

## 16. 调试方法论小结

这次排障中被证明有效(或用代价换来)的做法:

1. **只读优先。** Frida 探针默认只枚举、不调用。这条是用**两次**事故换来的:**永远不要对宿主进程的共享单例调用 `init` 系方法**(§3),**永远不要在非主线程调用 UIKit**(§12)——连探针也不行。必须调用时用 `ObjC.schedule(ObjC.mainQueue, ...)`,并且清楚 `ObjC.choose()` 会暂停进程所有线程。
2. **能不注入就不注入。** 需要运行时信息时,优先把 `respondsToSelector:` 探测写进插件自己的代码——它天然跑在主线程、在正确的生命周期时机,比外部注入安全得多。
3. **界面就是输出通道。** 拿不到日志、又不能注入时,把诊断值直接印进 UI(`CCPM_DEBUG_HEADER` 开关),截图回来就是精确数值。首次展开错位那个问题正是这么定位的——在此之前我按截图比例反推了两轮,全是猜。
4. **对照实验放到无关进程里做。** 验证「`initWithSuiteName:` 会不会毁掉宿主 defaults」时选了 Sileo 而不是 SpringBoard,拿到了干净的 81 → 34 数据且零风险。
5. **静态证据看未 strip 的 `.o`。** 发布二进制被 strip 后 `otool -tV` 没有符号标签,`.theos/obj/*/…​.o` 里方法名俱全。
6. **entitlement 是判断「这个操作被允许吗」的硬证据。** `ldid -e` 对比 `sbreload` 和 `killall`,一眼看出 backboardd 为什么拉不回来。
7. **trace 要带时间戳,并覆盖失败分支。** 第四轮如果没有把 `willTransitionToExpandedContentMode:` 也挂上,根本发现不了「菜单是被别人展开的」。
8. **Fail closed。** 确认框拿不到 scene 就不执行动作;长按计时器触发前复查状态。危险操作的失败方向必须是「什么都不做」。
9. **改造私有 API 行为时留退路。** 第四轮的闸门设计成「不被征询也只是退回原行为」,避免一次失败的猜测把已经修好的功能带崩。
10. **每次构建换版本号。** 1.0.2 → 1.0.13 每轮递增,`dpkg -l` 一眼确认手机上跑的是哪一版。
11. **改别人插件的配置,先读它怎么写。** Choicy 用 `writeToFile:` 而不是 CFPreferences,想当然地用 `NSUserDefaults` 会隔着 cfprefsd 的缓存,可能覆盖掉用户在对方界面里做的设置。键名对了不代表机制对了。
12. **保底通道常备。** 全程 SSH 在旁,`ssh iphone 'sbreload'` 是每次真机验证的救援手段(前提是 backboardd 还活着——这也是不再碰它的另一个理由)。

---

## 17. 提交历史

分支 `fix/roothide-ios16`:

```
Fix empty menu and stop hijacking the host's NSUserDefaults singleton
Make Respring and Reboot Userspace work on a roothide jailbreak
Confirm every action before it runs, and bump to 1.0.2
Open the menu on tap, respring on long press
Respring immediately on long press, without confirming
Ask the container whether the menu is open, not self.expanded
Take the long press back from Control Center's own expansion
Write up the roothide/iOS 16 port
Size the panel to its rows and make selection follow the finger
Translate the menu into Chinese
Show live device status in the menu header
Write up the status header, vibrancy and the first-expansion layout
Add a LetMeBlock toggle that shares its state with Choicy
Keep the menu open behind the confirmation, and agree with the settings switch
Draw the tile icon instead of parking a stopped spinner on it
```

---

## 18. 遗留与未验证项

诚实记录尚未在真机上跑过的路径:

- **Safe Mode**(`killall -SEGV SpringBoard`)未实测。它只影响 SpringBoard,最坏结果是一次 respring,不会黑屏;但 ellekit 在 roothide 上到底有没有实现安全模式没有验证。
- **Reboot Userspace 整条路径**未实跑(只验证到提权成功)。执行会重启整个用户态。
- **Restart / Shutdown** 未实跑(会真的重启/关机)。两者与 CCPower、PowerSelector 用的是同一个 API。
- **按下时的高亮/缩放动画**可能丢失:collapsed 状态没有调用 super(super 正是长按展开那段逻辑),按压反馈动画也在其中。用户未反馈异常。
- **锁屏状态下的确认框**未验证(`_canShowWhileLocked` 返回 YES)。
- 长按阈值固定 0.5 秒(`kLongPressDuration`),未做成可配置项。
- 设置页第 2 个 section 行数为 0(上游遗留),确认框开关等新选项若要做,可以放在那里。
- **设置页的条目名称仍是英文**(Respring / Safe Mode …),只有控制中心里的菜单做了中文化。
- **头部状态栏无法更亮**:它所在的 secondaryLabel 风格 vibrancy 层决定了亮度,颜色和字重都改变不了(§10)。要与行标题同亮度需换效果视图风格,副作用未评估。
- **全新安装后的第一次展开仍可能偏矮**:`headerHeight` 要等第一次展开结束才学得到。此后(含每次 respring)都正确。
- 状态栏每次显示都会读一次 IOKit / statfs / mach 统计,目前没有缓存;实测无感,但若以后加更多项值得测一下开销。
- **LetMeBlock 开关依赖 Choicy**:两者任一未安装时该项不显示。切换会重启 mDNSResponder,DNS 有短暂中断。
- 开关目前只针对 LetMeBlock 一个插件写死;若要做成「任选插件」,需要在设置页加一个插件选择器。
