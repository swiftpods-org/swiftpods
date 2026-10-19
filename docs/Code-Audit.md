# Аудит кода и рефакторинг SwiftPods

## Изоляция ресурсов: двадцатый проход, 17 октября 2026 года

Исправлены пять воспроизведённых дефектов: exclude_files соседнего subspec
удалял чужие on-demand resources; повторный ODR tag терял ранее объявленные
пути; app/test resources игнорировали собственные исключения; configuration
whitelist не исключал ODR files и не разделял их tags/categories; literal lproj
directory терял ODR tags и исключения дочерних ресурсов при раскрытии.

ODR declarations читаются отдельно для каждого выбранного consumer, затем
объединяются sets файлов и tags. App/test direct resources используют общую
NativeFileSelection.paths, как library resources и bundles. Configuration
exclusions учитывают ODR и сохраняют пути, необходимые другим enabled roots.
Для общего файла с разными tags в разных configurations NativeConditionalResources
создаёт стабильные managed symlinks с отдельными references и точными исключениями
по путям. Обычные ресурсы сохраняют исходные references; отдельный tagged child
внутри обычного каталога получает свою reference без лишней flattened copy.
Localization сохраняет lproj context. Categories/enable settings вычисляются для enabled roots.
Resource selection раскрывает lproj directories до фильтрации для direct/bundle/ODR
build inputs. Raw file-accessor paths для hooks сохраняют контракт reference.
Проба на Xcode 27.1 подтвердила: ASSET_TAGS не раскрывает build-setting variables;
отдельные references корректно создают asset pack или обычный bundle resource.

Постоянные регрессии: NativeResourceIsolationTests, обязательный suite
native:resource-isolation и проверка регистрации native regression scripts в
acceptance harness. Unit matrix охватывает osx/ios, три linkage modes, app/test,
file/directory exclusions, одинаковые tags, shared paths, разные конфигурации,
localization и идемпотентность. Integration matrix исполняет macOS apps/XCTest,
проверяет реальные iOS asset packs и содержимое обычных ресурсов в Debug/Release,
offline deployment, смену configurations и повторную deintegration.
Подпись и физическое исполнение на iOS devices остаются отдельными gates.

## Принадлежность файлов subspec: девятнадцатый проход, 17 октября 2026 года

Исправлены пять подтверждённых ошибок внутри общего pod target: compiler_flags
и requires_arc одного subspec применялись к соседнему, exclude_files удалял его
sources/resources, а разные header_mappings_dir и header_dir ломали установку
или consumer imports. NativeLibraryFiles сохраняет consumer, которому принадлежит
каждый файл. Общие compiler flags остаются на target, различные передаются файлам;
ARC masks/booleans определяются для исходников соответствующего consumer.

Sources, direct resources и resource bundle files выбираются и фильтруются до
объединения. Заголовки сохраняют собственные visibility, namespace и mapping;
framework copy phases и umbrella headers используют полученные пути. Автоматический
module map для archives сохраняет единственный выбранный header namespace;
при нескольких namespaces он располагается в namespace корневого module и ссылается
на выбранные публичные заголовки, включая соседние header namespaces. Отдельная
регрессия проверяет framework-style custom module map выбранного child subspec.
Framework project headers не требуют public/private mapping. Для archives
коллизии проверяются по нормализованному destination, включая разные записи
одного header_dir.

Регрессии: NativeSubspecFileTests и обязательный suite native:subspec-files.
Library/static/dynamic fixtures компилируют исходники с противоположными macro/ARC
условиями, исполняют consumer, проверяют заголовки и содержимое ресурсов/bundles,
offline deployment и смену выбранных subspecs. Подпись и physical devices остаются
отдельными gates.

Статическая проверка тестовой инфраструктуры: исправлены семь замечаний Ruff
(затенение platform, неиспользуемый import, lambda assignment и порядок imports).
Python scripts отформатированы по ruff.toml; изменения форматирования проверены
сравнением AST отдельно от этих явных правок.

## Каталоги specs, Mercurial и модули: восемнадцатый проход, 17 октября 2026 года

Исправлены шесть воспроизведённых ошибок. Local Mercurial sources используют
каталог manifest и полный origin в snapshot cache; исходный `:hg` сохраняется
в lockfile. Старые неоднозначные snapshots относительных путей не переиспользуются.

Для стандартного каталога `Pod/version/Pod.podspec[.json]` версии читаются из
индекса каталогов. Не выбранные resolver specs не парсятся и не исполняются;
выбранные проверяются полностью, включая identity, checksum и compatibility.
JSON имеет приоритет над Ruby podspec того же каталога. Flat catalogs сохраняют
предыдущий способ чтения. `:podspec => 'directory'` разрешается в `Pod.podspec`
относительно manifest, как в reference external source.

`compiler_flags` дополняют `OTHER_CFLAGS` из pod_target_xcconfig для libraries
и supplementary targets. ARC compatibility дополняет существующие linker flags.
Framework modules с одинаковым именем отклоняются, если одновременно линкуются
одним consumer/configuration. Для независимых consumers и configurations такие
продукты получают отдельные build directories. Статические archives с одинаковым
module name по-прежнему допускаются.

YAML boolean settings проверяются до применения: строка `"false"` больше не
включает ARC/BridgeSupport и не превращает concrete target в abstract. Настоящие
boolean и отсутствующие значения сохраняют прежнее поведение.

Регрессии: `NativeCatalogModuleTests`, `ruby_adapter_tests.rb` и обязательный
suite `native:catalog-module`. Проверяются реальные Mercurial repositories,
offline aliases, lazy catalog, выбранные identity errors, directory podspec,
сборка и исполнение libraries/apps и независимых static/dynamic frameworks.
Release signing/notarization и physical devices остаются отдельными gates.

## Git identity и очистка интеграции: семнадцатый проход, 17 октября 2026 года

Исправлены девять воспроизведённых ошибок. Относительные Git sources разрешаются
от каталога manifest независимо от cwd; checkout cache и commit aliases используют
полный local origin, поэтому одинаковые `./Kit` в разных проектах не разделяют
исходники. В lockfile сохраняется исходная декларация. Старый неоднозначный cache
от относительного пути не переиспользуется; его нужно наполнить повторно онлайн.

Ancestor discovery пропускает directories с именами manifest и в hardened mode
ищет JSON manifest. `why` получает раскрытые subspec/testspec/appspec selections
и зависимости, унаследованные через search paths.

Deintegrate использует сохранённые product receipts, если сгенерированный Pods
project уже удалён. Workspace XML и все существующие consumer graphs проверяются
до первой записи consumer. Ошибка workspace оставляет их и receipts неизменными.
Очистка исключённого проекта выполняется даже после физического удаления target;
неиспользуемые packages и stale configuration receipts удаляются, а пользовательские
ссылки на package сохраняются. Смена workspace удаляет только записанные managed
references из прежнего workspace, сохраняя пользовательские и вложенные references.
Generated xcconfig references учитываются отдельно от base configurations, поэтому
очистка удаляет их и при пользовательском base xcconfig. Используемые пользовательскими
объектами references сохраняются; legacy references распознаются по managed identity.
При удалении target из всё ещё выбранного проекта удаляются записи отсутствующих
configurations и неиспользуемые support references; остальные targets сохраняются.

Регрессии: `NativeSourceLocationTests`, `NativeWorkspaceRegressionTests` и отдельный
suite `native:ownership-source`. Проверяются общий cache двух проектов, ancestor/
explicit directory, offline deployment, explicit update, сборка и исполнение consumer,
повторная очистка и сохранение пользовательских объектов. Полная release acceptance,
подпись и device matrix остаются отдельными gates.

## Линковка и выбор manifest: шестнадцатый проход, 17 октября 2026 года

Исправлены девять подтверждённых ошибок. Static consumers получают `-ObjC`
и системные linker requirements выбранных pods с учётом configurations.
Те же требования применяются к supplementary targets и dynamic wrappers,
линкующим статические зависимости. ARC masks охватывают `.M`; явные
optimization settings сохраняются поверх configuration defaults.

Требование `cocoapods_version` проверяется для результата resolver и при lint,
поэтому невыбранная несовместимая версия каталога не ломает закреплённую
установку. Выбранная несовместимая версия по-прежнему отклоняется до hooks.

CLI передаёт найденный project root в engine. Общий выбор manifest учитывает
`CocoaPods.podfile.yaml`, `CocoaPods.podfile`, `Podfile`, `Podfile.rb`; checksum,
installation inputs и freshness используют фактически выбранный файл.
Serialized YAML target definitions загружаются через существующие DSL methods
без исполнения YAML source и без новых runtime dependencies; неизвестные
поля и object tags отклоняются.

Installation report сохраняет platform identity каждого spec, и `why`
обходит граф соответствующего consumer. Неоднозначные старые отчёты требуют
повторной установки. Исчезнувшие Xcode projects удаляются из ownership receipts;
deintegrate также обрабатывает оставшиеся legacy receipts и проверяет существующие
графы до первой записи.

Регрессии: `NativeLinkerManifestTests`, `ruby_adapter_tests.rb` и отдельный
обязательный suite `native:linker-manifest`. Он устанавливает и повторно
устанавливает fixtures, собирает и исполняет macOS consumers для library/static/
dynamic linkage, проверяет SQLite, system frameworks, ObjC categories, `.M`,
optimization settings, manifest aliases, platform graph и deleted-project cleanup.
Релизная подпись и device matrix остаются отдельными gates.

## Swift packages и исполняемые hosts: пятнадцатый проход, 17 октября 2026 года

`spm` мог успешно завершить установку с некорректными входами. Numeric products
исчезали, Boolean version превращался в строку `1`, неизвестные options
игнорировались, а обратные ranges сохранялись в проект. Общая модель декларации
теперь проверяет типы, options и version bounds до hooks и managed writes.
Writer использует ту же модель. Формы версий и их порядок сопоставлены с
`PackageDescription` установленного Swift toolchain; допустимые особенности
его parser не заменяются более строгими предположениями о semver.

Package declaration без products ранее полностью удалялся как неиспользуемый.
Теперь явно запрошенный package reference сохраняется до удаления декларации.
Проверены update, изменение products, повторная installation, removal и
сохранность `Package.resolved`. Отдельный локальный Swift package разрешается
Xcode, линкуется вместе с pod и исполняется в consumer application.

Проверки находятся в `NativeSwiftPackageDeclarationTests` и
`swift_package_regressions.py`, включённом в `native:lifecycle`. Ruby literal
helper fixtures теперь корректно представляет nullable values как `nil`.

Supplementary matrix раньше подтверждала только сборки. Её named app fixture
не использовал scene lifecycle и завершался при запуске на текущем SDK.
Fixture исправлен; runner выполняет Catalyst standalone/generated/named unit
tests. Дополнительный `--execute-ui` запускает Catalyst UI tests и записывает
отдельный execution report. Эти UI tests требуют macOS developer mode;
отсутствующая настройка даёт явную диагностику. Локальные probes сохранены
в `.build/audit15-probes`; полный release acceptance остаётся отдельным gate.

Release hosted tests также выявили ограничение локальной ad-hoc подписи:
hardened runtime отклоняет загрузку XCTest bundle из-за несовпадения Team ID.
Отдельный control подтвердил причину. Runner отключает hardened runtime только
в команде локального тестового запуска; настройки проектов и релизной поставки
не меняются. Проверка подписанной поставки остаётся отдельной.

Общий прогон также обнаружил недоступный на tvOS semantic color в новом app
fixture. Приложение использует базовые UIKit colors, доступные на всех выбранных
платформах; host matrix проверяется целиком, включая tvOS и visionOS.

## Большие дробные selectors: четырнадцатый проход, 17 октября 2026 года

Числовой Git tag `3826980940661245.5` преобразовывался в научную запись
`3.8269809406612455e+15`. Ruby сохраняет десятичную запись этого дробного
значения. Установка SwiftPods не находила существующий ref; изолированный
референс устанавливал тот же Podfile успешно.

Scalar formatter теперь сохраняет десятичную запись больших дробных значений,
не меняя научную запись целых Float и малых чисел. Swift-регрессия покрывает
положительные и отрицательные значения и границу целого Float. CLI-проверки
используют numeric `tag` и `commit` в Podfile и JSON podspec, реальные consumer
builds, повторную deployment/offline установку и явное обновление mutable tag.
Те же входы сравниваются с изолированным референсом.

Дополнительная детерминированная проверка сравнивает форматирование 29 982
конечных Double с внешним Ruby. Исходный reproducer находится в
`.build/audit13-final-review/float-selector-ehahb6y6`, отчёт исправления —
в `test-results/audit14-fixes.json`. Полная приёмка и внешние релизные gates
проверяются отдельно.

## Структурированные входы и Ruby API: тринадцатый проход, 17 октября 2026 года

Исправлены девять групп ошибок. Постоянные проверки находятся в
`NativeStructuredInputTests`, `ruby_adapter_tests.rb` и
`structured_input_regressions.py`. Новые consumer builds, archives и CLI-сценарии
включены в `native:lifecycle`; `native:compatibility` сравнивает одинаковые входы
и наблюдаемые значения с изолированным референсом.

| Ошибка | Исправление и проверка |
| --- | --- |
| Числовые Git selectors отклоняются | `tag` и `commit` принимают числовые значения в Podfile и podspec. `1` и `1.0` выбирают разные Git refs; проверены фактические исходники, consumer builds, deployment/offline lock и explicit update |
| Integral float превращается в integer | JSON-сериализация сохраняет `1.0`, `0.0` и знак `-0.0` в protocol, local specs и отчётах. Входы без floating values сохраняют прежние byte identities. Numeric strings используют корректное scalar spelling, включая большие integers |
| Quick lint пропускает вложенные ошибки | Проверяются scheme booleans/containers, script phases, ODR categories/paths, authors/license, default selections, ARC patterns и plist values во всех видах specs. Ошибки выявляются до hooks и managed writes |
| Development scheme теряет настройки | Общий writer применяет action configurations, arguments, environment и coverage к development и supplementary schemes. Проверены single/multiple projects и реальные unsigned archives с указанной конфигурацией Debug |
| Prefix header теряет числа из массива | Элементы соединяются с исходным scalar spelling и сохранением nullable/nested array semantics. Скомпилированный pod и запущенный consumer используют числовой macro |
| Xcconfig теряет составные значения | Numeric arrays, nullable values, integral floats и opaque hash values преобразуются в читаемые build-setting values вместо пропуска или позднего исключения. Hooks и Xcode видят итоговые значения |
| Ruby getters возвращают неверные типы | `source` и `license` используют Symbol keys; license text нормализуется без изменения raw data. Consumer сохраняет version objects, authors, screenshots, deprecated state и defaults |
| Consumer objects и platform validation расходятся | Эквивалентные запросы сохраняют identity. Consumer выбирает metadata по platform name; неподдерживаемое имя отклоняется. `supported_on_platform?` отдельно учитывает переданный deployment minimum |
| Boolean log visibility отклоняется | `show_env_vars_in_log: false` принимается и отключает environment logging. Не наследуем игнорирование этого флага референсом; отличие зарегистрировано с native/reference evidence |

Исходные `attributes_hash` сохраняются для hooks; нормализация применяется к
вычисляемым значениям и output representations. Archive fixtures не задают
build-only `SYMROOT` и явно включают библиотеку в archive через `SKIP_INSTALL=NO`.
Они проверяют действие scheme configuration, а не подписанную поставку.

Локальное evidence находится в `test-results/audit13-fixes.json` с привязкой
к исходникам, контракту, toolchain и бинарнику. Full packaged acceptance и
внешние релизные gates остаются отдельными проверками.

## JSON-значения и языки исходников: двенадцатый проход, 17 октября 2026 года

Исправлены шесть групп ошибок. Постоянные проверки находятся в
`NativeValueContractTests` и `value_contract_regressions.py`. CLI, consumer builds
и запуск приложений включены в обязательный `native:lifecycle`; одинаковые
JSON-входы проверяются native/reference compatibility suites.

| Ошибка | Исправление и проверка |
| --- | --- |
| Числовые dependency requirements исчезают | JSON `42` и `[42]` задают обязательное ограничение версии. Проверены успешная установка `42`, отказ для `100.0`, наследование ограничений и deployment reinstall |
| Числовой platform minimum проверяется слишком поздно | Ограничение участвует в resolver backtracking. Из `2.0` с minimum `14` и `1.0` с minimum `13.0` выбирается `1.0` для target `13.0`; несовместимый локальный pod отклоняется до hooks и записи проекта |
| Числовые Swift versions отклоняются | Поддержаны `swift_versions: [5]`, смешанный массив и legacy `swift_version: 5`. Выбранная версия используется в реальной сборке, а исходные числовые значения доступны hooks. Некорректный scalar `swift_versions: 5` по-прежнему отклоняется |
| `.C` и `.M` отсутствуют в Compile Sources | Выбранные файлы компилируются как C++ и Objective-C++, участвуют в расчёте стандартных linker flags. Проверены линковка и запуск consumer applications |
| Допустимые pod names отвергаются | Поддержаны графические символы, включая `Kit@Core`, `📦Kit` и `Kit's`; проверены module import, framework build и deployment lock. Скрытые имена, whitespace, control characters и path traversal отклоняются |
| Ошибочные JSON-контейнеры незаметно теряются | Проверяются serialized object shapes, nested deployment targets, dependency requirements, URL/options и resource bundle patterns. Quick lint и install выдают диагностику до hooks; числовой resource pattern больше не превращается в успешную пустую bundle |

Нормализация версий применяется к вычисляемым атрибутам; исходные spec data
сохраняются для checksums и Ruby hooks. String `platforms` сохраняет смысл,
массив вместо String/Hash отклоняется. Явная диагностика malformed resource
patterns заменяет позднее исключение референса; воспроизводить его crash не требуется.

Локальное evidence записывается в `test-results/audit12-fixes.json` с source,
contract и binary digests. Оно не устанавливает stable acceptance и не заменяет
полный packaged-запуск, signing/notarization и внешние релизные gates.

## Каталоги, входные данные и Metal: одиннадцатый проход, 16 октября 2026 года

Исправлены восемь дефектов одиннадцатого аудита. Постоянные проверки находятся
в `NativeCatalogRegressionTests` и `catalog_build_regressions.py`; CLI и consumer
builds включены в обязательный `native:lifecycle`.

| Область | Исправление |
| --- | --- |
| HTTP payload | Обновление spec repositories отделено от обновления исходников. Обычный и deployment install с `--repo-update` сохраняют архив и lock; явный update обновляет выбранный payload. Проверяются serial и parallel downloads |
| Git/CDN catalogs | Update освежает используемые каталоги по умолчанию; `--no-repo-update` сохраняет cached revision/index. Offline не выполняет fetch. Зарегистрированные Git updates и snapshots сериализуются отдельным repository lock |
| Metal | Явно выбранные `.metal` включены в Compile Sources с правильным file type. Ошибочный shader отклоняется; корректный создаёт metallib в framework и во встроенном продукте приложения |
| Brace glob | Видимость dotfiles определяется фактической позицией в path segment, независимо от порядка, вложенности и пустых альтернатив |
| Quick lint | Типы проверяются рекурсивно во всех subspec/test/app trees и platform attributes. Test type проверяется до установки и сборки |
| Unicode names | Pod и dependency identity поддерживают Unicode letters, marks и numbers; запреты path traversal и separators сохранены |
| Generated strings | Ruby и shell literals экранируются отдельно от YAML lockfile. Init сохраняет апостроф в project/target names; spec lint принимает пути с апострофом |
| Outdated | Installed, manifest-compatible и latest versions различаются; ограничения manifest не скрывают новые версии. Есть `--ignore-prerelease` |

Восстановление повреждённого source cache выполняется явным `update POD`,
поскольку `--repo-update` меняет только каталоги. Успешные локальные проверки
записываются в `test-results/audit11-fixes.json` с привязкой к source/contract
digests и binary. Они не заменяют полную packaged-приёмку и внешние релизные gates.

## Загрузка исходников и lint: десятый проход, 16 октября 2026 года

Исправлены девять дефектов десятого аудита. Постоянные регрессии находятся в
`NativeResolutionInputTests.swift`, `ruby_adapter_tests.rb`,
`source_input_regressions.py` и `lint_input_regressions.py`. Два последних набора
включены в `native:lifecycle` и проверяют CLI, hooks и реальные consumer builds.

| Ошибка | Исправление и проверка |
| --- | --- |
| Символьный commit/revision обходит checkout pin | Неизменные install и deployment используют immutable checkout из lock, включая новый пустой cache; explicit update разрешает новую ревизию Git/Mercurial |
| Targeted update повторно использует старый HTTP archive | Checksum входит в cache identity; update обновляет named download. Проверены serial/parallel downloads, source без checksum и offline переключение между двумя проверенными версиями |
| ZIP теряет внешнюю папку | Default flatten зависит от формата; ZIP сохраняет layout, tar-like archives разворачивают wrapper. Explicit true/false имеют приоритет; проверены source patterns и сборка |
| Pod Lint подменяет consumer scheme | Lint собирает конкретный target конкретного consumer project; broken/valid public headers проверены для library/framework |
| Lint пропускает optional subspecs | Отдельная установка и consumer build для root и каждого применимого library subspec, включая nested; fail-fast сохраняет свою семантику |
| Unicode header_dir меняет module identity | Swift и Ruby используют фиксированные Latin approximations без новых runtime dependencies; проверены explicit module_name, scalar boundaries и импорт Ecole |
| Кавычки в комментарии портят include path | Include заканчивается своей закрывающей кавычкой; комментарий не попадает в filename. Проверены analysis, resolved settings hook и Xcode |
| CRLF разрывает continuation | CRLF нормализуется до объединения строк; LF и CRLF дают одинаковые effective settings и consumer build |
| UI test_type и target label расходятся | Specification и Consumer возвращают Symbol; JSON/Ruby inputs и default unit type согласованы. Hook находит созданный UI target и сохраняет его изменения |

Сохранение immutable checkout для символических selectors — намеренное
исправление общей с референсом ошибки. Contract регистрирует
`Sources.mutable_checkout_pins`; native/reference suites сравнивают одинаковый
manifest и отдельно подтверждают explicit update. Входные Podfile не требуют
переписывания.

Старые HTTP download entries можно использовать только после проверки требуемой
checksum. Подготовленные HTTP snapshots имеют отдельную версию правил layout,
чтобы ранее развёрнутый ZIP не подменял новую интерпретацию исходного архива.

Локальное evidence находится в `test-results/audit10-fixes.json` с привязкой
к source/contract digests и binary. Оно не заменяет signing/notarization,
физические устройства, Intel/minimum macOS, чистую Homebrew установку,
удалённый CI и полный host matrix.

## Входной контракт и достоверность проверок: девятый проход, 16 октября 2026 года

Исправлены десять дефектов девятого аудита и ошибка собственных зависимостей
при `inherit! :none`. Постоянные проверки находятся в `NativeInputContractTests`,
`NativeConsumerBuildTests`, `input_contract_regressions.py`, Ruby adapter tests
и acceptance harness. CLI/consumer-регрессии включены в `native:lifecycle`.

| Область | Исправление |
| --- | --- |
| Snapshot cache | Дерево и provenance закреплены отдельным receipt; `cache verify` и установка отклоняют изменённые revision/origin. Mutable pod ownership сохраняется отдельно |
| Incremental state | Identity, fingerprint и checkout проверяются вместе и сверяются с lock pin; legacy state проходит повторную установку через проверенный source path |
| Lint | Помимо pod targets собирается отдельный интегрированный потребитель, импортирующий публичные ObjC/Swift interfaces через общий расчёт platform/subspec attributes, visibility и header mappings; сломанный публичный header больше не даёт ложный успех |
| ODR | Cleanup использует общий расчёт файлов для кратких и полных описаний. Локализованные ODR остаются отдельными файлами с собственными tags; обычные локализации сохраняют variant groups |
| Module identity | Вычисляемые имена нормализуются одинаково в Swift и Ruby; явно заданный C99 identifier сохраняется. Hook product/module names соответствуют реальному target |
| Module maps / requires | `module_map=false` отключает автоматическую карту библиотеки; разрешённый импорт DSL корректно перехватывается своим адаптером |
| Installer | Extraction и payload используют отдельные пространства внутри staging; archive roots `prefix` и `archive` не конфликтуют с ними |

Старые snapshot receipts не подтверждают provenance. Их можно просматривать и
удалять; для использования требуется обновление источника (`--repo-update`).
Повреждённый incremental state даёт явную диагностику и требует `--clean-install`.
Lockfile не переписывается на ревизию из повреждённых метаданных.

Расширенная проверка восстановила совместимые target names уникальных
supplementary bundles. При коллизиях сохраняются scoped names и отдельные
каталоги продуктов; регрессия запускает независимые apps и проверяет их payload.

`inherit! :none` ограничивает наследование родительских зависимостей и их
configuration whitelist, сохраняя собственные зависимости target. Это намеренное
исправление общей с референсом ошибки, зарегистрированное как
`Targets.none_own_dependencies` в contract. Неизменный manifest и результат
сборки дочернего consumer проверяются в native/reference compatibility suites;
явно указанные собственные configurations остаются в силе.

Локальное evidence записывается в `test-results/audit9-fixes.json` с привязкой
к исходникам, контракту и binary. Оно не заменяет внешние release gates и не
означает полной приёмки версии 1.0.

## Consumer builds: восьмой проход, 16 октября 2026 года

Исправлены шесть дефектов восьмого аудита. Постоянные регрессии находятся в
`NativeConsumerBuildTests.swift`, расширенных header/visibility tests,
`ruby_adapter_tests.rb` и `consumer_build_regressions.py`. Последний набор
включён в `native:lifecycle` и проверяет реальные сборки macOS и payload приложений.

| Ошибка | Исправление и проверка |
| --- | --- |
| Одинаковый `module_name` сталкивает статические архивы | Имя архива определяется pod target label, имя модуля сохраняется отдельно; проверены обе библиотеки в одном приложении, Ruby API, повторная установка и запуск |
| Неявно непубличные headers отсутствуют в namespace производителя | Producer tree содержит все source headers; consumer tree сохраняет только публичные. Проверены namespace import, private visibility и реальная сборка |
| Public-header glob без совпадений скрывает заголовки | Fallback определяется раскрытым набором файлов; проверены пустые/отсутствующие/unmatched и совпадающие patterns, исключение private/project headers и наблюдения hook |
| Custom module maps отсутствуют у app/test targets | Общие compiler flags применяются к supplementary dependency closure с сохранением пользовательских flags; проверены app и XCTest сборки |
| Независимые app specs конфликтуют по bundle basename | Коллизии проверяются внутри destinations конкретного consumer; отдельные apps сохраняют свои одноимённые bundles. Коллизии собственных и транзитивных bundles внутри одного app по-прежнему отклоняются |
| Platform не нормализует допустимые аргументы | Constructor принимает копию Platform, имена/aliases и deployment hash; `supports?` нормализует аргумент. Проверены version boundaries, hash equality и настоящий post_install hook |

Для одноимённых bundles сравнение с референсом не считается проверкой корректной
изоляции: в аудите референс принимал manifest, но заменял payload первого app
ресурсами второго. Регрессия SwiftPods проверяет содержимое каждого bundle и
запускает оба приложения.

Локальный результат записывается в `test-results/audit8-fixes.json` с привязкой
к source/contract digests и бинарнику. Это не заменяет внешние release gates.

Расширенная проверка обновляет устаревшие ожидания supplementary bundle target
names. Assembly app fixture задаёт `ENABLE_DEBUG_DYLIB=NO`: две preview-link
операции Xcode 27 использовали один dependency-info файл и повреждали его.
Обычные app/test сборки и исполнение продолжают проверяться; поддержка preview
dylib в assembly-only app этим fixture не подтверждается. Исходный неуспешный
проход сохранён в `.build/audit8-fixes-first-pass`.

## Владение фазами, headers и module maps: седьмой проход, 16 октября 2026 года

Исправлены восемь воспроизведённых ошибок. Регрессии находятся в
`NativeHeaderOwnershipTests.swift`, `ruby_adapter_tests.rb` и
`header_ownership_regressions.py`; интеграционные сценарии запускаются через
`native:lifecycle`.

| Ошибка | Исправление и проверка |
| --- | --- |
| Установка удаляет legacy script phases чужого target | Очистка ограничена targets текущего проекта, выбранными manifest; общие объекты сохраняются, пока используются другим target. Проверены install, повторная установка и deintegrate |
| Static library не видит private headers по namespace | Public и Private header trees строятся отдельно для каждого variant; producer получает private/project headers, consumers — public paths. Проверена реальная сборка |
| Custom module map теряется у consumer | Авторская карта передаётся Clang и Swift consumers, включая зависимости между pod targets. Framework-style декларации для static library нормализуются в управляемой копии; исходный файл сохраняется |
| `before_headers` запускается после mapped copy | Script position учитывает все header copy phases; script phases применяются после формирования mappings. Проверены свежие public/private headers в static и dynamic frameworks |
| Составные pod/bundle names имеют общий PBX ID | Identity строится из отдельных variant/owner/bundle полей; неоднозначные display names получают детерминированный suffix. Проверены две независимые apps, правильный payload и неизменность графа при reinstall |
| Sandbox lookup использует полное subspec name | Поиск directory/specification выполняется по root; сохраняется идентичность specification. Проверены локальные и remote paths и настоящий hook |
| Platform не сравнивается с Symbol | Обычное `==` поддерживает Symbol; `eql?` остаётся типизированным и согласованным с hash. Проверены ветвление hook и Hash keys |
| Bundle name с `_` или `+` создаёт неверный identifier | Identifier нормализуется через `PRODUCT_NAME:rfc1034identifier`; имя bundle и payload сохраняются. Проверен фактический Info.plist собранных bundles |

Набор generated-header fixtures сохраняет отдельное предупреждение Xcode 27
о задержке Copy Headers tasks несандбоксированным script. Это advisory build
system, а не compiler warning: оно записывается в `*-advisories.json` рядом с
полным log. Только эта точная диагностика допускается в соответствующем
fixture; остальные warnings и ошибки запрещены. Скрипты не переводятся
принудительно в sandbox, который изменил бы их доступ к исходникам и файлам.

Общий результат прохода находится в `test-results/audit7-fixes.json` и связан
с текущими source/contract digests и бинарником. Локальные проверки не заменяют
релизную приёмку и внешние gates.

## Workspace, bundles и headers: шестой проход, 16 октября 2026 года

Исправлены пять воспроизведённых дефектов шестого прохода. Постоянные проверки
находятся в `NativeWorkspaceRegressionTests.swift`, `NativeConsumerAssetTests.swift`,
`ruby_adapter_tests.rb` и `workspace_resource_regressions.py`. Последний набор
включён в `native:lifecycle`.

| Ошибка | Исправление и проверка |
| --- | --- |
| `deintegrate` удаляет пользовательский workspace FileRef во вложенной группе | Пути разрешаются с учётом всей цепочки Groups. Старые receipts применяются только к корневым ссылкам, которые мог создать installer; проверены повторная установка, удаление и сохранность пользовательского проекта |
| Одноимённые resource bundles разных pods перезаписываются | Владение хранится по product ID, target names и output directories включают pod variant. Library, static framework и dynamic framework доставляют каждому приложению его собственный `Shared.bundle`; проверены реальные сборки, payload и deintegration |
| Private framework headers теряют относительные каталоги | Mapping применяется отдельно к Public и Private destinations. Проверены вложенные и плоские заголовки, Project visibility и реальная сборка с импортом `<Kit/Private/Inner.h>` |
| `Lockfile.version(root)` не находит установленный subspec | После точного поиска используется полное совпадение root name. Сохраняются subspec names, отсутствующие зависимости возвращают `nil`; проверен hook с настоящим lockfile при install и deployment |
| `Version.eql?` принимает строку с несовместимым hash | Hash equality ограничено объектами Version; обычное сравнение со строкой сохранено. Эквивалентные версии, включая metadata и разную точность release, остаются одним ключом Hash/Set |

Два bundles с одинаковым именем в одном consumer получают явную диагностику,
если нужны одновременно в одной конфигурации. Разные конфигурации не считаются
коллизией; разные приложения и вложенные dynamic frameworks сохраняют свои bundles.
Удаление интеграции не удаляет исходники и файлы пользователя.

Локальный результат этого прохода записывается в `test-results/audit6-fixes.json`.
Он не подтверждает внешние release gates и не означает stable acceptance.

## Исходники, prerelease и Ruby API: 16 октября 2026 года

Исправлены пять дефектов пятого прохода. Постоянные CLI-регрессии добавлены в
`source_api_regressions.py` и запускаются через `native:lifecycle`. Сравнение
версий проверяется также unit-тестами Swift, Ruby adapter tests и изолированным
resolver reference runner.

| Ошибка | Исправление и проверка |
| --- | --- |
| Явно выбранные `.s`/`.S` видны hooks, но не компилируются | Library, app и test targets включают assembly в Compile Sources; проверяются реальные сборки и XCTest. Directory defaults и `other_source_files` сохраняют прежнюю семантику |
| Resolver теряет prerelease `.0` и неверно сортирует числа относительно текста | Release и prerelease сравниваются отдельно в Swift и Ruby; точное требование не принимает другую prerelease, metadata не меняет порядок, hashing согласован с равенством |
| Унаследованный `GIT_DIR` позволяет неуспешной публикации изменить оригинал | Внутренние Git-команды очищают переменные выбора repository/index/object storage; сетевые настройки и credentials сохраняются. Проверены отказ hook, повторная публикация, registry revision и `http.extraHeader` |
| Повторный install снова запускает prepare локального pod | Успешная подготовка записывается для конкретного podspec и пути. Неизменный install, offline и deployment её пропускают; изменение podspec, targeted update и clean install запускают снова. Пользовательские исходники не копируются, не очищаются и не блокируются |
| YAML/Marshal повреждают Ruby Version | Сериализация сохраняет исходную строку, requirements, comparison и hashing; проверены metadata, compound/numeric prerelease и применение внутри настоящего hook |

Receipt подготовки локального pod хранится внутри `Pods/Target Support Files`.
Неуспешная подготовка не записывает успех; hardened policy проверяется и при
наличии receipt. Изменение пользовательского исходника само по себе не требует
повторной подготовки. Побочные эффекты скрипта в локальном checkout находятся
вне rollback установки, как и другие внешние Ruby/shell side effects.

Эти проверки не заменяют внешние gates подписанной поставки и release acceptance.

## Версии, репозитории и Xcode paths: 16 октября 2026 года

Закрыты пять ошибок четвёртого прохода. CLI-регрессии находятся в
`metadata_repository_regressions.py`, запускаются через `native:lifecycle` и
дополняют `NativeAuditCompatibilityTests.swift`, Ruby adapter tests и
сравнительные resolver tests.

| Ошибка | Исправление и проверка |
| --- | --- |
| Допустимые версии с build metadata и составным prerelease отклоняются | Swift и Ruby сохраняют spelling, metadata не меняет precedence или prerelease; проверены requirements, hooks, lockfile/deployment и выбор metadata variants |
| Регистрация specs repo делает кеш несовместимым с предыдущим install | Repository snapshots используют NativeGitCache receipt; старый plain receipt проверяется, затем snapshot восстанавливается из закреплённого registered checkout; проверены оба способа доступа и повреждение provenance |
| Условия target xcconfig используют унаследованный SDK после его переопределения | SDK-контекст учитывает project settings, target xcconfig и более приоритетные target settings; проверены переменные, циклы, hooks и эффективные настройки Xcode |
| projectDirPath игнорируется при разрешении paths | Единый sourceRoot используется при анализе, интеграции и в Ruby file references; проверены повторный install, сборка macOS-приложения и deintegrate |
| Отказ local-only публикации оставляет staged podspec | Commit готовится в отдельной копии с Git hooks/config; исходный checkout проверяется перед заменой, отказ сохраняет его чистым; проверены повторная публикация, полный lint и rollback при ошибке записи metadata |

Локальные проверки не подтверждают signing, notarization, удалённый CI или
остальные внешние release gates.

## Дополнительные исправления: 16 октября 2026 года

Закрыты пять дефектов следующего прохода. Постоянные CLI-регрессии находятся в
`lifecycle_audit_regressions.py` и запускаются обязательным `native:lifecycle`;
проверки include-chain, циклов SDKROOT и старых cache aliases добавлены в
`NativeLifecycleRegressionTests.swift`.

| Ошибка | Исправление и проверка |
| --- | --- |
| `post_integrate` меняет собственный SwiftPM объект, следующий install ошибочно сообщает внешнюю правку | Ownership проверяется до hook и обновляется после его успешного завершения, включая явный `project.save`; настоящая внешняя правка по-прежнему блокируется |
| Поздний SDKROOT скрывает условный deployment target | Условия вычисляются с итоговым SDKROOT, в том числе через includes и переменные; порядок присваиваний сохраняется, циклы получают диагностику; проверены hook, Xcode settings и сборка приложения |
| Дубликаты pod/SwiftPM проверяются по всем проектам и сырым именам | Используются фактические module identities зависимостей конкретного target; проверены независимые приложения и совпадение через `header_dir` |
| `deintegrate` оставляет собственные Swift packages | Удаляются записанные package attachments и неиспользуемые собственные объекты; пользовательский пакет сохраняется |
| Поименная очистка пропускает commit-копию checkout | Владельцы записываются до создания копии и объединяются под lock; при очистке старых записей владение восстанавливается по проверенному происхождению, общие исходники сохраняются для других pods |

SwiftPM-регрессии проверяют установку и сохранённый граф Xcode; удалённые
пакеты этих fixtures не скачиваются и не собираются. Локальные проверки
не заменяют отдельные gates подписанной поставки и внешней инфраструктуры.

## Повторный аудит: 16 октября 2026 года

Исходная ревизия повторного прохода — `1ae34d2`. Исправлены 13 воспроизведённых
ошибок и ранее отмеченная потеря shared pins при адресном обновлении.

| Область | Исправленный результат | Постоянная регрессия |
| --- | --- | --- |
| Удалённые consumer targets | Управляемые ссылки, зависимости и настройки очищаются; другие targets и пользовательские изменения сохраняются | `native_lifecycle_tests.py`, `NativeLifecycleRegressionTests.swift` |
| Swift packages | Собственные requirements обновляются; исключённые package/product/build references удаляются с учётом владельца и оставшихся пользователей | `NativeLifecycleRegressionTests.swift`, `native_lifecycle_tests.py` |
| Consumer xcconfig | Флаги нескольких pods объединяются, явные пользовательские overrides сохраняются | Сборка приложения в `native_lifecycle_tests.py` |
| Deployment target | Переменные раскрываются после объединения project/target settings; циклы получают диагностику | `NativeLifecycleRegressionTests.swift`, `native_lifecycle_tests.py` |
| Ruby Specification | Изменение живой коллекции `subspecs` достигает сериализации и resolver | `ruby_adapter_tests.rb`, offline-установка в `native_lifecycle_tests.py` |
| Ruby Xcode API | Работает `source_build_phase`; `avoid_duplicates` возвращает существующий build file | `ruby_adapter_tests.rb`, настоящий post_install в `native_lifecycle_tests.py` |
| Git cache | Receipt связывает дерево и неизменяемые данные checkout; повреждение не переписывает lockfile | `NativeLifecycleRegressionTests.swift`, отказ/recovery/refresh в `native_lifecycle_tests.py` |
| Адресная очистка cache | Сопоставляется точное имя pod, а не подстрока URL или другого имени | `NativeLifecycleRegressionTests.swift`, offline deployment в `native_lifecycle_tests.py` |
| Shared pins | Разблокировка использует всех родителей полного графа, включая одинаковые dependency strings | `NativeCompatibilityTests.swift`, адресное и совместное обновления в `native_lifecycle_tests.py` |
| Evidence | Tested bundle/executable identity сверяется с индексом, текущим manifest и фактическими файлами | `acceptance_tests.py` |
| Installer | Повторная установка проверяет launcher и отказывается считать посторонний файл успешной установкой | `acceptance_tests.py`, `native_distribution_tests.py` |
| Отмена runner | SIGTERM разворачивает cleanup дочерних процессов; threaded runner передаёт отмену workers | `acceptance_tests.py` |

`NativeDeintegrator.restore` используется и для полной deintegration, и для
очистки исключённых consumers. `NativeSwiftPackageIntegrator` записывает
принадлежащие установке объекты и подключения отдельно от пользовательских.
Новый обязательный набор `native:lifecycle` включён в общий acceptance runner.

Старый Git cache без receipt происхождения требует online refresh перед
использованием; просмотр и очистка доступны после проверки дерева. При просмотре
такой кеш не сообщает непроверенную revision. Автоматическая привязка старых
метаданных к дереву не выполняется.

Для одинаковых dependency strings сохранение shared pins намеренно отличается от
референса, который теряет связь со вторым родителем. Сравнительный тест фиксирует
оба результата и проверяет явное обновление общей зависимости; отличие объявлено
в `Profiles/contract.json` как исправление при неизменном формате входных данных.
Старые packaged reports без digest bundle требуется получить заново. Эти
изменения не меняют формат Podfile, podspec или lockfile.

## Первый проход

Дата: 15 октября 2026 года. Исходная ревизия: `2cb1d49`.
Область: собственное Swift-ядро, C-модуль процессов и архивов, Ruby-адаптер,
Python-инструменты и регрессионные тесты. Сторонние исходники, лицензии,
замороженные отчёты и готовые дистрибутивы не форматировались.

Исходные 92 Swift-теста проходили с warnings-as-errors. Аудит проверяет
дополнительные входы и наблюдаемые эффекты: успешная исходная сборка не
исключала перечисленные ниже ошибки.

## Исправленные ошибки ядра

| Ошибка | Последствие | Исправление и проверка |
| --- | --- | --- |
| Нули перед prerelease-компонентом участвовали в сравнении | `1.0.a` и `1.a` считались разными версиями | Канонические типизированные компоненты версии; регрессии сравнения |
| Пессимистическая верхняя граница принимала prerelease следующего release | `~> 1.2.3.a` мог разрешить `1.3.a` | Отдельная release-граница; проверяется и условие, и решение resolver |
| Точность `~>` определялась строковым разбиением | `1.2.3a` и большие числовые компоненты задавали неверную границу | Числовые компоненты и их исходная точность сохраняются без переполнения |
| Пустые части условий исчезали при `split` | Пустое условие или запятая разрешали больше версий вместо ошибки | Пустые clauses отклоняются; пустой список условий сохраняет значение по умолчанию |
| Разблокировка учитывала только первый target с одинаковым именем зависимости | Порядок targets менял результат обновления закреплённой версии | Проверяются все требования текущих targets |
| Нормализация `:git` и `git` создавала дублирующийся ключ Dictionary | Некорректный lockfile завершал процесс аварийно | Явная ошибка схемы для неоднозначных source options |
| Удалённый JSON podspec терял расширение в content cache | JSON попадал в Ruby evaluator; query в URL также мешал выбору формата | Типизированная кешированная проекция с проверкой целостности и общим lifecycle кеша |
| Невалидный JSON podspec публиковался в кеше до проверки | После неудачной установки переставали работать просмотр и очистка кеша | Проверка JSON object и имени спецификации предшествует публикации; регрессия сохраняет кеш доступным |
| Flatten архива перемещал дочерний каталог на занятое родителем место | Архив `release/release/Kit.swift` не устанавливался | Общая подготовка архива с промежуточным переносом; проверены flatten и checksums |
| Числовая Mercurial revision игнорировалась | `:revision => 0` устанавливал HEAD, а не указанную ревизию | Целая ревизия нормализуется; проверены настоящий двухкоммитный репозиторий, reinstall и offline |
| Неверные типы checksum и archive type игнорировались | Ошибочная настройка проверки содержимого превращалась в no-op | Общая валидация source options с явной диагностикой |
| Неверный тип списка PBX references пропускал проверку hooks | В проект записывались `children: [123]` или `files: "bad"` с успешным результатом | Все известные reference lists требуют строки UUID; 18 неверных входов подтверждены failing-прогоном |
| Пустая команда доходила до `removeFirst()` | Внутренний вызов завершал процесс аварийно | Проверка command envelope до исполнения; сохранены diagnostic/completed events |

Регрессии: `NativeResolverAuditTests.swift` и `NativeCommandAndLockTests.swift`.
Исходные ошибки версий и JSON входов подтверждены отдельным failing-прогоном;
flatten и числовая Mercurial revision — самостоятельными воспроизводителями.

## Исправленные ошибки Ruby API

Один и тот же набор из 18 проверок запущен на исходном и новом Runtime:
15 проверок падают на исходной ревизии и проходят после исправления.

| Область | Исправленный результат |
| --- | --- |
| Живые PBX collections и вложенные build settings | Коллекции, сохранённые hook до refresh, продолжают менять тот же проект |
| UUID после повторного открытия проекта | Новый объект не затирает ранее созданный объект с теми же атрибутами |
| Пути вложенных project groups | Ссылки на subprojects учитывают путь родительских групп |
| ObjectList | Range/slice возвращают объекты; `delete` отсутствующего элемента возвращает `nil` |
| Specification traversal | Test/app specs не дублируются; `default_subspecs :none` сохраняет смысл |
| `all_dependencies` | Возвращаются непосредственные и выбранные default-subspec edges, а не случайно развёрнутая транзитивная цепочка |
| Podfile dependencies | Сохраняются разные требования к одноимённой зависимости |
| External source metadata | HTTP, SVN и Mercurial options доступны объектам hooks |
| PluginOptions | Изменения через Symbol и значения внутри массивов сохраняют indifferent access |
| Platform consumers | Symbol нормализуется к имени платформы; дочерняя декларация без minimum наследует minimum родителя |
| Некорректный lockfile | Выдаётся ошибка входа вместо `NoMethodError` |

`Runtime/runtime.rb` загружает публичные объекты без запуска IPC.
`Runtime/session.rb` владеет транспортом, callbacks и состоянием одной команды.
Исполняемый `Runtime/dsl.rb` остаётся точкой входа адаптера.

`scripts/ruby_adapter_tests.rb` не требует test gems и включён в обычный
`check.py` до интеграционных fixtures. Дополнительно проверяются framing JSON,
пользовательский stdout, SyntaxError, явный exit, исходный backtrace и живые
closures между фазами.

## Исправленные ошибки приёмки и поставки

| Ошибка | Исправленный результат |
| --- | --- |
| Проверка toolchain падала до инвалидирования старого отчёта | Старый `passed` сразу заменяется текущим состоянием и затем `failed` |
| Повреждённый частичный JSON скрывал исходную ошибку | Сохраняются первоначальная причина и корректный failure report |
| Отмена общего запуска оставляла дочерние процессы | Общий runner останавливает принадлежащие ему process groups, включая вложенные fixtures |
| Portable evidence не содержал файлы внешних gates | Экспорт включает проверяемый inventory артефактов; отсутствующие или изменённые bytes запрещают stable evidence |
| `13.0` сравнивалась с `13.0.0` как меньшая версия macOS | Отсутствующие компоненты версии нормализуются к нулю |
| Покрытие installation options зависело от кавычек Ruby-кода | Все 15 опций берутся из версионированного реестра контракта |
| `--bundle=PATH` не учитывалась при выборе бинарника и имени отчёта | Обе формы аргумента связывают проверку с поставляемым бинарником и packaged report; отсутствующий путь даёт failure report |

Старые nonstable evidence-архивы остаются читаемыми. Наличие артефакта не
подменяет содержательную проверку соответствующего внешнего gate.

## Архитектура и стиль

`NativeEngine` стал входным facade; состояние команды принадлежит
`NativeCommandSession`. Lockfile, hook runner, версии, источники и модели
спецификаций выделены по ответственности. Xcode generation разделена на
строительство library variants, связи, aggregate targets и сборку графа;
user integration и Swift package integration отделены от генерации.

Ruby-код разделён на specification, target inheritance, project objects,
file accessors, installer и transport session. В Python общий process runner и
`VerificationStages` заменяют повторяющийся код запуска и отмены.

Swift/C, Ruby и Python приведены к общему стилю каждого языка. Конфигурации
форматирования сохранены в репозитории; dev-only инструменты находятся в
игнорируемой `.build`. Карта компонентов и команды проверки описаны в
[Development](Development.md).

Рефакторинг генерации и hooks дополнительно проверен независимым сравнением
токенов с исходным кодом: сохранены порядок фаз, callbacks, products/settings,
project identity и протокол событий. Изменения поведения отделены регрессиями.

## Границы результатов

### Платформа и условные настройки SDK

При автоматическом определении платформы проверяются все конфигурации target.
Неверный SDK или неразрешённый deployment target одной конфигурации не могут
молча исключаться из анализа. `SDKROOT=auto` с минимумами нескольких платформ
требует явной платформы в Podfile; пустые значения минимумов не создают
дополнительную платформу. Абсолютные пути SDK распознаются по имени
bundle, без влияния названий родительских каталогов.

Условия `[sdk=…]` используют имя SDK и при абсолютном `SDKROOT`. Изменение SDK
через условие конфигурации пересчитывает настройки проекта, target и включённых xcconfig;
циклы завершаются `SP-XCCONFIG-CYCLE`. Исходное значение `SDKROOT` сохраняется.
Обязательный `native:platform-inference` сравнивает результат с Xcode, проверяет
отказ до hooks/записей для Ruby/YAML Podfiles, реальную сборку и запуск macOS
потребителя и идемпотентную установку offline/deployment.

### Строки Xcode schemes

Аргументы и переменные окружения schemes сохраняют tab/LF/CR и CRLF точно:
writer использует XML character references, предотвращая замену пробелов при
XML attribute normalization. CocoaPods 1.17.0 воспроизводит ту же потерю данных;
исправление без изменения входов зарегистрировано как `Scheme.XML_whitespace`.
NUL, запрещённые C0 controls и U+FFFE/U+FFFF отклоняются `SP-SPEC-SCHEME` до hooks
и записей. Допустимые XML whitespace и Unicode, включая non-BMP, сохраняются.

Регрессии проверяют XML round-trip в library/test/app schemes, одиночный и
multiple-project development scheme, Debug/Release XCTest с реальными значениями
окружения и отказ quick lint/install для некорректных строк до pre_install.

### Скалярные значения PBX после hooks

При сохранении PBX используются строковые представления Ruby: `nil` становится
пустой строкой, boolean сохраняется как `true`/`false`, float — с десятичной частью
и корректным форматом экспоненты. Преобразование применяется рекурсивно к массивам
и словарям, сохраняя их структуру. Это позволяет очищать compiler flags через
`build_settings['OTHER_CFLAGS'] = nil` без появления аргумента `<null>`.
Unit tests проверяют Foundation round-trip; обязательные native/reference xcconfig
fixtures сравнивают наблюдаемые Xcode значения и реальные сборки Debug/Release.

Проверка ownership управляемых Swift package objects сравнивает их сохраняемое
PBX-представление. Поэтому `nil` в hook и сохранённая пустая строка не вызывают
ложный `SP-SPM-CONFLICT` при повторной установке или deintegrate. Реальные изменения
значений и структуры контейнеров по-прежнему считаются конфликтом. Lifecycle
регрессия проверяет два install, явный `project.save`, внешний edit и deintegrate.

### Границы версий CocoaPods

Классификация prerelease отделена от сравнения версий, как в CocoaPods:
`1.0.0-0` равна `1.0`, оставаясь prerelease для фильтра кандидатов.
Числа после дефиса до первой буквы участвуют в release-компонентах: `1.2.3-4`
равна `1.2.3.4`. Это сохраняет точные ограничения и precision для `~>`.
Версии `1-a`, `1--`, `1-2`, которые профиль CocoaPods не принимает, отклоняются.
Unit tests и девять дополнительных случаев `reference:resolver` проверяют
реальное разрешение зависимостей, включая ложные конфликты и неверный выбор версии.

### Значения xcconfig

Поддерживаются комментарии `//`; маркеры `/*…*/` внутри значений не удаляются.
Отдельные C-комментарии отклоняются как синтаксис, который Xcode не собирает.
Рекурсивные пути `/**/` и кавычки сохраняются при чтении настроек
и в `resolved_build_setting`. Маркеры внутри `//` не могут поглотить последующие
настройки; литералы с маркерами и продолжения строк LF/CRLF не меняют физические
номера строк диагностики.
`native:xcconfig` и изолированный reference проверяют значения и реальные сборки
Debug/Release после переноса quoted recursive header path через Ruby hook.

### Условия xcconfig и буквальные include-пути

Пробелы перед условием и между selectors сохраняют семантику Xcode. Пробелы
внутри имени условия или pattern остаются частью строки. NUL не может обрезать
pattern/context при вызове `fnmatch` и ошибочно применить настройку. Повреждённый selector
не может применить только корректную часть условия; для файлов он завершается
`SP-XCCONFIG-SYNTAX` с исходным file/line. Ключи `xcconfig`, `pod_target_xcconfig`
и `user_target_xcconfig` проверяются до hooks, downloads и managed writes.

Директивы включения разбираются целиком: поддержаны `# include` и `# include?`,
trailing comments; неизвестные directives, лишние prefix/suffix tokens и пробел
перед `?` отклоняются `SP-XCCONFIG-INCLUDE`. Пути включений остаются буквальными,
включая `$(NAME)`, `${NAME}` и `$(SRCROOT)`; отсутствующее optional-включение
не может случайно прочитать файл по раскрытому пути.

Unit tests проверяют синтаксис и точные результаты. Обязательный native xcconfig
набор сравнивает наблюдения hooks с Xcode, строит и запускает Debug/Release consumer,
проверяет offline/deployment reinstall и неизменность inputs. Отрицательные fixtures
проверяют отказ до hooks/записей, исходные file/line и реальные ошибки Xcode build.

### Glob-классы и полное имя файла

Символьные классы glob не пересекают `/`, включая отрицательные классы и классы
с явно указанным separator. Литеральная `[` через `[[]`, escaped members и `&`
не включают синтаксис ICU regular expressions. Границы диапазонов приводятся к одному регистру до сравнения. Сохранены диапазоны и профильные
пустые/обратные диапазоны; незакрытый класс отклоняется. `\A`/`\z` проверяют
полное имя, предотвращая совпадение перед завершающим LF/CR/CRLF/Unicode separator.
Сопоставление использует NFC-представление имён, сохраняя исходный URL. Границы
путей проверяются по filesystem components; ведущий combining mark не теряется.

Unit tests проверяют точные наборы путей. Обязательные native/reference fixtures
сравнивают source files, exclusions, public/private headers и resources без изменения
podspec. Ruby 3.4.11 включает closing `]` в некоторых классах и неодинаково учитывает регистр в class members/ranges; исправление с прежними
входами зарегистрировано как `Glob.character_class_matching`. Lifecycle строит и
запускает Debug/Release consumer для source/exclusion boundaries, literal bracket
смешанного регистра диапазона, Unicode-имени и точного resource filename, затем проверяет offline/deployment reinstall.

### Синтаксис xcconfig и пути workspace

Xcode не поддерживает операторы присваивания `+=` и `?=` в xcconfig. Успешный
`-showBuildSettings` скрывает их ошибку; реальная сборка отклоняет такие строки.
SwiftPods выдаёт `SP-XCCONFIG-SYNTAX` с исходным файлом и строкой до hooks и
записей. Для наследования используется допустимое `VALUE = $(inherited) extra`.
Unit tests и обязательные xcconfig fixtures проверяют оба оператора в корневом
и вложенном файле, отсутствие изменений и соответствующую ошибку реальной сборки Xcode.

При сохранении workspace tab/LF/CR в XML attributes кодируются character references.
Это сохраняет пользовательские и добавленные пути, предотвращает потерю схемы
приложения и дублирование ссылок при reinstall. Comments, CDATA, processing
instructions и DTD не участвуют в перекодировании. Unit tests проверяют точные
значения, literal entities и различающиеся whitespace пути; lifecycle fixture
проверяет install/reinstall/deintegrate, реальный Xcode `-list` для tab/LF/CR
и сборки Debug/Release проекта с tab в родительском каталоге.

### Публичный интерфейс при lint

Lint использует `NativeLibraryFiles`, как и генерация library targets: исключения,
public/private/project masks, `header_dir` и `header_mappings_dir` применяются к
владеющей файлами подсхеме. Объединение атрибутов больше не скрывает заголовки
соседней подсхемы и не подменяет её путь импорта. C++ и Objective-C++ проверяются
через `Probe.mm`, включая библиотеки только из C++-заголовков; C/Objective-C и
Swift сохраняют соответствующий язык проверки.

Для C++-пробы включаются Clang C++ modules явным `-fcxx-modules` с сохранением
унаследованных флагов. Автоматический module map статической
библиотеки с отличающимся `header_dir` передаётся потребителям явно, включая
Clang, Objective-C++ и Swift: поиск модуля больше не зависит от совпадения имени
модуля и каталога заголовков.

`native:lint-interface` входит в обязательный реестр. Он проверяет отказ на
конфликтующем объединённом публичном интерфейсе, успех после исправления,
разные пространства заголовков и C++-интерфейсы в library/modular/framework
режимах реальными сборками macOS. Dependency и consumer targets собираются с
`-parallelizeTargets`, без предупреждения Xcode об устаревшем ручном порядке.

При targeted update SwiftPods сохраняет всех родителей общей транзитивной
зависимости, включая одинаковые строки ограничений. Обновление одного родителя
сохраняет pin, принадлежащий также неизменённому родителю; явный выбор общей
зависимости для update разблокирует её. В CocoaPods reference одинаковые строки
дедуплицируются, что может потерять такого родителя. Отличие закреплено случаями
`Resolver.shared_pins_preserved` и `Resolver.shared_pins_explicit_update` и
зарегистрировано как `Resolver.shared_dependency_pins` в контракте.

### Unicode-границы файловых путей

Сравнение путей через строковый `hasPrefix` и срезы по `String.count` теряло
границу `/`, когда следующий компонент начинался с комбинируемого символа,
например U+0301. Исключённые исходники попадали в сборку, явно выбранные папки
теряли файлы, `header_mappings_dir` отклонял корректные заголовки, а очистка
загруженного pod удаляла нужные исходники или содержимое сохранённых папок.
Та же причина нарушала группы Xcode, копирование папок ресурсов и ODR-алиасы.

Эти операции используют компоненты файлового пути, сохраняя имена файлов.
Проверка symlink проходит компоненты до обработки `..` и сравнивает физические
границы без повторной Foundation-стандартизации: dangling ссылки внутри pod
остаются допустимыми, выходящие за его границу отклоняются.

Регрессии проверяют исключения, папки, заголовки, очистку и symlink через
публичный FileAccessor с CocoaPods reference. Шесть consumer fixtures собираются
и запускаются в Debug/Release; повторная offline deployment-установка сохраняет
оба проекта, lockfile и исходный podspec. Runtime-проверка папки ресурсов
подтверждает её структуру и отсутствие лишней копии вложенного файла в корне bundle.

### Имена pod/subspec и параметры CLI

Glob-операторы разбираются по Unicode scalar: combining mark после `*`, `?`,
`[`, `]`, `{`, `/` или escape не превращает оператор в литерал. NFC применяется
к цельным literal runs, а объявленные members/ranges внутри класса сохраняют
свои scalars. Семь native/reference cases сравнивают точные file sets; Debug/Release
consumers вызывают функцию из каждого выбранного файла, а лишний source содержит
compile error. Offline deployment reinstall сохраняет проекты, lock и podspec.

NUL в file/pattern attributes, resource bundle names/paths, license file и ODR
paths отклоняется до hooks, prepare и записей проектов. `prepare_command` с NUL
тоже отклоняется заранее. Нижний process layer проверяет executable, argv и env
до преобразования в C strings, предотвращая молчаливое выполнение усечённой
команды. Script phase path lists отклоняют также CRLF, несмотря на один Swift
Character. Проверены точные отказы и сохранность пользовательских inputs.

Границы имён разбираются по scalar `/`, включая разделитель перед начальным
combining mark подсхемы. Одинаковые правила применяются к root identity, lookup
вложенных library/test/app specs, наследованию атрибутов, вариантам Xcode,
dependency graph, lockfile pins/update и lint consumers. Суффиксы имён targets
сохраняют полный Unicode-текст. Корневые имена отклоняют slash, начальную точку
и backslash даже перед combining mark; custom project name не допускает slash.

`header_dir` и `header_mappings_dir` отклоняют абсолютный путь и компонент `..`
по файловым границам, включая `/` перед combining mark. ASCII/Unicode controls
проверяют одинаковый отказ и сохранность пользовательского проекта; относительные
Unicode-каталоги проходят Debug/Release сборки, запуск и offline reinstall.

Integrity проверяет компоненты пути и физическое расположение источников внутри
Pods. Корректный nonlocal pod с начальным combining mark проходит record/verify;
traversal и выходящие root aliases отклоняются до замены receipt. Для root alias
внутри Pods записывается содержимое целевого дерева, поэтому изменение исходников
обнаруживается. Старый receipt, хранивший только alias, требует явного record после
установки ожидаемого графа; receipts обычных каталогов сохраняют прежний fingerprint.

Doctor проверяет slice/library paths, framework executable, app executable и
embedded frameworks по объявленному контейнеру. Абсолютные/обходные пути и aliases
наружу отклоняются; относительные Unicode paths, внутренние aliases и versioned
frameworks поддерживаются. Регрессии используют настоящие Mach-O libraries,
executables и dylibs; статическая проверка не выполняет пользовательский Podfile.

Inline CLI values разделяются по scalar `=`, сохраняя начальный combining mark.
Ранний выбор project directory использует тот же парсер, что и command envelope:
inline/split формы равнозначны, а empty/missing/duplicate значения отклоняются
до создания project state в неверном каталоге. Неявный поиск Podfile вверх
по каталогам сохраняется.

Регрессии сравнивают прямой, вложенный и default Unicode-subspec с CocoaPods;
строят и запускают Debug/Release consumers и проверяют immutable offline
deployment reinstall, включая custom multiple-project name. Lint отклоняет
сломанный публичный заголовок Unicode-subspec и принимает исправленный с
compiler warnings as errors. Unit tests проверяют также graph roots, lockfile
edges, variant labels и ссылки на именованные app hosts.

### Восстановление, перенос проекта и runtime

Журнал восстановления, inventory генерируемых проектов, проверка SDK и runtime
также используют компоненты файлового пути. Ведущий U+0301 больше не превращает
внутренний проект во внешний, не дублирует journal entries и не скрывает файлы
в запрещённых runtime/vendor/gems каталогах. Скрытые каталоги проверяются по
начальному байту точки; Ruby внутри дистрибутива отклоняется до запуска probe.
XCFramework metadata отклоняет абсолютные пути, вложенный LibraryIdentifier
и CR/LF, включая CRLF, остающийся одним Swift Character.

Парсер workspace разделяет prefix и путь по Unicode scalar `:`. Для генерируемой
относительной ссылки с начальным combining mark добавляется `./`: без него Xcode
теряет схему, хотя непосредственный project и absolute reference работают.
Сохранённые относительные объявления проектов участвуют в переносимом evaluated
checksum. Старый checksum принимается только при точном воспроизведении прежнего
написания пути, сохраняя остальные вычисленные объявления. Повторный deployment
и перенос сохраняют lockfile; изменение динамических requirements отклоняется.

При переносе ownership records меняют ключи проектов и workspace, сохраняя
значения original/written для точного восстановления и защиты пользовательских
изменений. Созданные SwiftPods base xcconfig references присоединяются заново;
пользовательские references сохраняются. Неоднозначная старая запись внешнего
проекта требует install с исходными объявлениями вместо угадывания пути.

Обязательные lifecycle fixtures проверяют recovery/conflict, перенос внутреннего
Unicode-проекта, копирование внешнего проекта, immutable legacy lock, deintegrate,
generated project cleanup и SDK paths. Реальные Debug/Release consumer builds
дополняются запуском приложения и offline deployment reinstall. Runtime suite
и packaged CLI повторяют семь containment/Ruby boundary cases.

### Дескрипторы процессов и имена переменных окружения

Имена переменных окружения не могут быть пустыми или содержать `=`/NUL.
Общий валидатор применяется до OS serialization и при проверке library/test/app
schemes. Раньше `FIELD=SUFFIX` превращался в `FIELD` со значением `SUFFIX=value`;
это воспроизведено в настоящем XCTest. Quick lint и install теперь отклоняют
такие declarations до hooks, prepare и записей проектов. Проверяются точные
diagnostics и сохранность Podfile, podspec, пользовательского проекта и lock.
Допустимые Unicode-имена, пробелы, пустые значения и литеральный `=` сохраняются;
Debug/Release XCTest проверяет фактическое окружение процесса.

ToolProcess захватывает stdin до создания output pipes. Закрытый descriptor 0
получает EOF через отдельную копию `/dev/null`, исключая чтение собственного
output capture pipe и блокировку. Standalone harness компилирует production
sources с минимальной macOS проекта и warnings-as-errors; семь комбинаций
закрытых standard descriptors проверяют stdin/stdout/stderr, а контрольный
запуск проверяет точное наследование входных данных. Обычный CLI с закрытым
stdin проходил исходную проверку и сохранён как контроль совместимости.

### Конкурентное владение потоками и состояние сигналов

Параллельный ToolProcess мог закрыть fallback descriptor 0 между захватом stdin
и созданием pipes в другом вызове. Следующий вызов наследовал чужой capture pipe.
В исходном reproducer 91 из 4800 вызовов вернул неправильный результат. Общий
владелец streams синхронизирует allocation и освобождение fallback; его lifetime
явно удерживается до завершения readers. Блокировка покрывает владение streams,
а дочерние команды выполняются одновременно. Unit test проверяет это барьером
из четырёх реально запущенных команд и отдельными stdout/stderr tokens.

ThreadSanitizer подтвердил чтение массива PID монитором одновременно с записью
при spawn. Registry и cancellation state используют lock-free integer atomics,
проверенные static assertions для signal handler. Обработчик сохраняет `errno`:
при смоделированном допустимом отказе `kill` исходный код менял EDOM на ESRCH.

Обязательный lifecycle suite включает 18 новых групп. Семь сочетаний закрытых
standard descriptors повторяются в `-Onone` и `-O`: 11200 реальных tool executions
проверяют EOF и уникальные stdout/stderr tokens. Ещё 672 отклонённых NUL inputs
проверяют очистку ресурсов на ошибках. Два сценария cancellation запускаются
под ThreadSanitizer; два errno controls проверяют пустой и заполненный registry.
Новые fixtures воспроизводят все три дефекта на сохранённых исходниках до правок.

### Время жизни PID и NUL в объявлениях источников

Обычный wait отправлял group signal после waitpid, когда PID уже был освобождён.
Контроль с настоящим waitid подтвердил сигнал без владения PID. Задержанный
forwarding показал освобождение PID до завершения ранее начатого сигнала;
неизвестный PID мог привести к завершению самого изолированного test process.
Теперь waitid с WNOWAIT удерживает ребёнка, registry исключает повторное ожидание,
retiring slots не переиспользуются, а reaping следует за завершением signal readers.
Terminate проверяет принадлежность PID. Пустые/чужие waits возвращают ошибку.
Десять обязательных cases проверяют normal, pending, unknown, duplicate, failed,
concurrent wait и terminate; два случая выполняются под ThreadSanitizer.

NUL в `:path` и глобальном `source` преобразовывался в буквальный `%00` и мог
выбрать другой существующий каталог, выполнить hook и изменить проект. Общая
проверка source strings, selectors и headers отклоняет NUL до интерпретации пути;
global sources проверяются до cache lease. 47 отрицательных CLI cases проверяют
точную диагностику и сохранность inputs. Literal-percent development paths,
Unicode paths и percent catalog проходят offline deployment reinstall, а шесть
Debug/Release consumers реально собираются и запускаются. Новые fixtures
воспроизводят PID, path и catalog дефекты на исходном коде до правок.
CLI с inherited ignored SIGCHLD проходил baseline/current control; отдельный
дефект этого сценария не подтверждён.

### Unicode-ключи данных и пути xcconfig include

Foundation сохранял разные последовательности Unicode в ключах NSDictionary,
но приведение к Swift Dictionary молча объединяло канонически эквивалентные
написания. В JSON и Ruby podspec две environment_variables превращались в одну;
ipc и install могли сохранить разные значения. Reference CocoaPods сохранял обе
записи. Общая проверка Foundation containers до Swift bridging отклоняет такие
коллизии с SP-DATA-KEY. Она применяется к JSON read/write, DSL replies/callbacks,
JSON lockfiles, cached podspec projections и существующим PBX graphs. Отдельное
допустимое NFC/NFD-написание сохраняется без нормализации.

NUL в обязательном или optional xcconfig include выбирал существующий файл с
буквальным %00 и приводил к изменению проекта. Xcode 27.1 на этих некорректных
входах аварийно завершал разбор; эта ошибка внешнего инструмента не считается
исправленной в Xcode. SwiftPods отклоняет NUL до создания URL и optional existence
check, с SP-XCCONFIG-INCLUDE и точным файлом/строкой, включая nested includes.
Обычный Project.open уже отклонял NUL на стороне Ruby и сохранён как контроль.

Десять новых unit tests воспроизводят потери данных, cache writes и неверный
include на исходном коде до правок. Постоянные lifecycle fixtures проверяют
JSON/Ruby library/test/app specs, IPC/quick lint/install, OpenStep/XML projects,
JSON lockfile, hook replies/callbacks и recovery. Допустимые Unicode-ключи,
literal-percent/Unicode include names проходят offline deployment reinstall
и Debug/Release consumer builds с исполнением приложений.

Тестовый OpenStep serializer сохраняет Unicode непосредственно в UTF-8:
JSON escape вида \\u0301 интерпретировался OpenStep как другое написание.
Ruby fixture strings также сохраняют Unicode без несовместимых JSON surrogate
escapes. Обратное чтение проекта проверяет фактические ключи до запуска регрессии.

### PBX-пути, project inventory и Unicode lockfile

NUL в PBXFileReference.path, PBXGroup.path и projectDirPath выбирал существующий
literal-%00 путь, запускал hooks и позволял install изменить проект. PBX graphs
проверяют path/projectDirPath/projectRoot при чтении, перед сохранением и перед
применением hook graph. SP-XCODE-PATH возникает до интерпретации URL. Проверка
живых build-setting queries также защищает изменённые in-memory references.
Hook callbacks сохраняют обычную Ruby-обёртку SP-DSL-ERROR с исходным diagnostic.
Неверный hook graph не записывается; lifecycle tests проверяют recovery.

Повреждённый inventory с NUL в relative path мог удалить существующий %00 project
при совпадении fingerprint. SP-XCODE-INVENTORY теперь отклоняет такую запись до
разрешения пути и cleanup. Сопоставление через NSString regex ranges сохраняет
разделители перед combining marks: раньше допустимая схема с начальным U+0301
ошибочно отклонялась после генерации. Literal-percent и Unicode receipts проходят
удаление ранее управляемых файлов с сохранением пользовательских изменений.

После исправления inventory повторная deployment/offline установка Unicode pod
обнаружила отдельный дефект YAML. Native parser считал отступы и разделители
Swift Characters; combining mark присоединялся к пробелу или кавычке. Ruby читал
тот же сгенерированный lockfile успешно. Структурные tokens, whitespace, quotes,
flow/sequence separators и comments разбираются по Unicode scalars/буквальным
UTF-16 ranges. Значения сохраняются без нормализации; tags/anchors/aliases
по-прежнему отклоняются явно.

Ссылка shared scheme на Unicode child project также могла терять container
prefix для Xcode. В изолированном сравнении обычное имя собиралось, имя с U+0301
давало «not configured for the build action», а изменение только ссылки на
container:./ сохраняло нужный проект и восстанавливало сборку. Генератор добавляет
dot component, когда combining mark нарушает распознавание container prefix.

16 новых unit tests и постоянные lifecycle fixtures проверяют OpenStep/binary
projects, относительные/абсолютные references, IPC, hook save/reply, receipts с
совпадающими и различными fingerprints, recovery, offline deployment и реальные
Debug/Release consumers. Unicode shared schemes собираются в single/multiple
projects; связанный с их static archive consumer исполняет исходный C API.

Полная проверка также обнаружила нестабильность Xcode 27.1: preview и debug
linker tasks C app fixture используют один dependency-info файл и могут
выдать «unexpected EOF». В compiler-flags fixture эти задачи выполняются
с `-jobs 1`; debug dylibs остаются включены. Три повторные чистые сборки
собрали и запустили приложение без предупреждений. Проверка warnings-as-errors
сохранена; это ограниченный обход гонки внешнего Xcode в тесте, а не исправление
самого Xcode.

### YAML-документы, типы metadata и физические xcconfig строки

Native YAML отклонял допустимые inline comments после кавычек и collections,
терял элементы flow sequences с апострофом внутри plain value, добавлял null при
trailing comma и менял mapping pairs на строки. Неэкранированные кавычки и
непарные delimiters, напротив, принимались в hardened install и lockfile
переписывался. Lexer различает начало quoted scalar и кавычку внутри plain text,
проверяет баланс tokens и сохраняет исходный файл/строку в диагностике.

Числа и YAML 1.1 boolean spellings превращались в строки при сохранении metadata.
Разбор сохраняет scalar types, точные integer values в поддерживаемом диапазоне
и поведение закреплённого Psych scanner, включая sexagesimal notation.
Непредставимые числа отклоняются явно. Block scalars, chomping и folding
сохраняют значения; пустой literal больше не превращается из пустой строки в
символ `|`. Несколько документов больше не объединяются в один lock graph.
Вложенность ограничена; invalid escapes и raw control characters имеют
диагностику. YAML encoder проверяет Foundation dictionary keys до bridging.

NativeLock.quote пропускал апостроф перед combining mark. Первичная установка
создавала lockfile, который Ruby не мог прочитать. NEL мог менять путь при Ruby
folding, а U+2028/U+2029 ошибочно считались физическими YAML строками в Swift.
Общая запись scalar strings сохраняет Unicode spelling и экранирует controls
и line separators. При семантически неизменном lock graph и профиле сохраняется
исходный текст с comments и formatting. Изменённые checksums и граф записываются
с сохранением типов неизвестных metadata.

Реальная сборка выявила ещё одну границу: Xcode делил xcconfig value на U+2028
и U+2029. Перемещение только этой настройки в pbxproj восстанавливало Debug и
Release consumer execution. Generator сохраняет непредставимые в xcconfig
settings и condition keys в project graph, сохраняя полный merged consumer
value. Проверка keys действует до выбора места хранения. Native xcconfig reader
также сохраняет NEL как данные, как это делает Xcode.

Постоянный корпус YAML сравнивает данные с Ruby reader. CLI fixtures проверяют
DSL и hardened режимы, ранний отказ без managed writes, побайтовое сохранение
допустимых inputs, настоящую запись при смене podspec checksum и последующую
offline deployment установку. Отдельно проверяются Ruby lock read, native
resolved build settings и Debug/Release applications для Unicode paths.
LF/CR paths сохраняют прежний отказ и recovery. Новые project fixtures удаляются
в finally; журналы и lockfile reproductions остаются для evidence.

### Разделители VCS source и общий кеш

Путь `./\u0301Repo:tag` ошибочно сохранялся относительным: Swift Character
объединял `/` с combining mark, поэтому проверка не видела разделитель каталога.
Два независимых проекта с таким объявлением делили cache identity. Установка
второго проекта завершалась успешно, но получала исходник первого (`7` вместо
`19`) и его commit/revision в lockfile. Ошибка воспроизведена для Git и Mercurial.
Обратная ошибка возникала в SCP-style Git address: combining mark после `:`
скрывал colon и превращал remote address в локальный путь до вызова transport.

Распознавание `/` и `:` использует Unicode scalars. Физические local identities
по-прежнему разрешаются относительно Podfile с canonical symlink resolution;
удалённые адреса и literal percent sequences сохраняют исходное spelling.
Постоянные unit regressions охватывают combining marks, variation selectors,
ZWJ, absolute/parent paths и aliases. CLI fixtures проверяют Git в DSL/hardened
и Mercurial в DSL, два проекта с общим кешем, точный lock revision, восстановление sandbox
в offline deployment, alias reuse и явное обновление одного проекта без смены
pin другого. Debug/Release consumers проверяют фактические значения функции.
SCP transport проверяется локальным SSH helper с точным requested path и без
сетевого соединения; offline reinstall не вызывает transport повторно.
Прямой Hg source в hardened manifest сохраняет предусмотренный schema отказ
без managed writes. Новые project fixtures очищаются через TemporaryDirectory.

### Каноническое имя выбранного SDK

Условия `[sdk=macosx27.*]` проверялись по исходному `SDKROOT = macosx`.
Xcode использует versioned `SDK_NAME` из metadata выбранного SDK. Поэтому
native reader пропускал version-specific flags и ошибочно применял точное
условие `[sdk=macosx]`. Та же ошибка возникала для абсолютного SDK bundle
без версии в имени. Через `resolved_build_setting` ошибка попадала в hooks:
установка и Debug/Release сборки были успешны, но приложение получало `0`
вместо ожидаемого `7`. SDK alias с другим basename также приводил к
`SP-PLATFORM-MISSING`, хотя Xcode корректно определял SDK и платформу.

Общий SDK context читает `CanonicalName` из SDKSettings.json/plist и разрешает
символические SDK через xcrun в developer environment текущей команды.
SDKROOT в пользовательских настройках сохраняет исходное значение. Tool lookups
принадлежат одной команде; bundle metadata читается заново, включая retargeted
symlinks. Контекст передаётся через platform inference, init, xcconfig/PBX
conditions и Ruby callbacks. Глобального кеша SDK между окружениями нет.
Недоступные bundles сохраняют прежний lexical fallback для анализа проекта;
наличие и пригодность SDK подтверждаются отдельной сборкой.

Повторный разбор нашёл ту же grapheme-границу у кавычек перед combining mark:
SDKROOT ошибочно сопоставлялся с basename вместо literal значения. Проверка
кавычек использует Unicode scalars; CLI результат сверяется с Xcode.

Unit regressions проверяют canonical metadata, JSON/plist, aliases, raw values,
взаимодействие project/target settings, поздние includes, deployment inference,
раздельные developer environments и обновление metadata. CLI regressions
сравнивают Debug/Release settings с настоящим Xcode для девяти SDK и разных
SDKROOT spellings; проверяют install/init, offline deployment и исполняемые
macOS consumers. Сравнение настроек других SDK не считается запуском на
устройстве. Временные проекты удаляются через TemporaryDirectory.

### Владение процессами в contract harness

Таймаут Python subprocess.run убивал только CLI и оставлял запущенный им
xcodebuild. В наблюдённом случае XCTest выполнил ожидаемо падающий тест, но
завершение внешнего test runner зависло. Журналы и process sample сохранены.
Contract CLI helper теперь пишет отдельные stdout/stderr logs во время работы,
владеет process group и при таймауте или отмене посылает SIGINT перед forced
cleanup. Лимит 180 секунд, failing test и warning gates сохранены. Постоянные
regressions проверяют отдельные streams, nonzero exit status и таймаут с
дочерним процессом: signal, reaping и partial logs. Это исправление harness,
а не утверждение об исправлении внутренней ошибки XCTest.

### Стандартные переменные проекта в SDKROOT

Native settings не содержали SRCROOT, SOURCE_ROOT, PROJECT_DIR, PROJECT_NAME,
PROJECT_FILE_PATH, CONFIGURATION и TARGET_NAME, доступные в Xcode. Поэтому
SDKROOT через такие переменные оставался нераскрытым, version-specific SDK
условия не применялись, а неявная платформа отклонялась с
SP-PLATFORM-MISSING. При явной платформе install и Debug/Release сборки были
успешны, но hook передавал приложению 0 вместо ожидаемого 7.

Reader добавляет defaults выбранного проекта, конфигурации и target и сохраняет
пользовательские overrides. SOURCE_ROOT по умолчанию следует SRCROOT; PROJECT_DIR
остаётся структурным source root проекта, пока пользователь не переопределит его.
ProjectDirPath учитывается, а PROJECT_FILE_PATH сохраняет положение xcodeproj.
SDKROOT и другие пользовательские declarations сохраняют исходное spelling.
Раскрытые значения используются для анализа и SDK-условий.

Относительный SDK выбирается от структурного source root, включая bare bundle
name. Он не зависит от cwd CLI или переопределения переменной PROJECT_DIR.
Macro path с PROJECT_DIR, напротив, учитывает её явное значение. Подтверждено
сравнением разных реальных SDK в двух каталогах. Metadata SDK используется для
специфических SDK-patterns только при фактически разрешённом bundle: basename отсутствующего
SDK больше не включает sdk-условия. Lexical fallback остаётся только для
platform analysis. Неизвестные macros не превращаются в SDK по последнему
компоненту пути. Неизвестные пользовательские переменные сохраняют прежнее
literal значение. Семантика literal xcconfig includes не меняется.

Пути PBX base configuration files раскрывают те же стандартные переменные
в обеих формах: `$(NAME)` и `${NAME}`. Выбранные CONFIGURATION и TARGET_NAME
передаются из analysis, hooks и integration. Раньше такие корректные ссылки
завершались SP-NATIVE-ERROR; Xcode читал эти же файлы. NUL после раскрытия
отклоняется до создания URL. Проверки путей и циклов групп сохраняются.

Unit regressions проверяют стандартные defaults, overrides, project/target
layers, source-root redirection, macro syntaxes, относительные пути и отсутствие
SDK. Постоянные CLI fixtures сравнивают переменные с Xcode, проверяют implicit
platform install/init, исходные SDKROOT declarations, offline deployment и
Debug/Release application execution. Временные проекты удаляются.

### Контекст условий и путей к базовым конфигурациям

Pattern `*` делает условие универсальным: для `[sdk=*]`,
`[arch=*]` и даже неизвестной оси Xcode не требует значения контекста. Reader
раньше отбрасывал такие условия при отсутствии оси или metadata SDK. Шаблоны
`**`, `?*`, basename отсутствующего SDK и literal unknown axis остаются
специфическими и без подходящего контекста не применяются. Контекст и pattern с NUL не проходят
проверку даже в универсальном условии.

При отсутствующем или пустом SDKROOT Xcode использует default macOS SDK для
условий. Исходная декларация сохраняет отсутствие или пустое значение.
`SDKROOT = auto` остаётся literal значением без SDK identity; подходят только
универсальные SDK-условия. Поздний `auto`, в том числе из include или
условного присваивания, перевычисляет предыдущие условия. Project и target
оцениваются с общим итоговым SDK, включая переход к пустому значению или auto.

Target base configuration reference раскрывается в project scope. Доступны
проектные build settings, проектный xcconfig, цепочки variables и conditions;
переопределение в target меняет возвращаемое setting, но не выбранный file.
Project base reference не может использовать собственные project declarations.
SOURCE_ROOT как source tree остаётся структурным корнем; macro SOURCE_ROOT
учитывает проектный SRCROOT override. TARGET_NAME получает default actual target
после project settings и перед target overrides. Этот контекст общий для
analysis, hook queries, проверки подключения generated xcconfig и lint consumers.
NUL после раскрытия и использованный variable cycle получают отдельную
диагностику. Неиспользованный cycle не мешает читать корректный file.

Новые unit regressions сначала воспроизводят дефекты на baseline Sources.
CLI fixtures проверяют Xcode settings для Debug/Release, implicit platform/init,
byte-stable offline deployment и output собранных macOS applications. Негативные
reference scopes проверяются до hooks/managed writes. Временные проекты удаляются.
Literal xcconfig includes сохраняют прежнюю семантику.

### Выражения настроек и буквальные пути: проход 44

Подтверждены пропуск SDK conditions при неизвестных variables и modifiers,
ошибочный повторный разбор буквальных project/configuration/target names и
source roots, ложные cycles и запись физических путей как Xcode expressions.
До исправления собранное приложение получало expansion=0 вместо 7; root с
буквальным $(SDKROOT) приводил к ложному cycle, а исправление только reader
оставляло неоткрываемые generated xcconfig references при реальной сборке.

NativeBuildSettingScope сохраняет bindings исходных assignments отдельно от
raw declarations, отличает literal defaults от expressions и переносит inherited
bindings между scopes. Scalar parser поддерживает вложенные имена, обе формы
скобок, short references, dollar escaping и modifier chains. SDK/path evaluation
подставляет empty для неизвестных variables, обычные declaration queries
сохраняют неизвестные references. Для platform inference unavailable SDK
сохраняет unresolved spelling при lexical fallback: неизвестный каталог перед
MacOSX.sdk не должен выбирать macOS по basename. Полностью пустое выражение
и фактически найденный SDK используют effective value. Полный lifecycle
выявил эту границу; отдельный unit test воспроизводит три failures до исправления,
прежняя early-rejection regression сохраняется. Известные retrieval/replacement operations
проверяются по установленному Xcode; неизвестные operations не меняют operand.
String/list backslash behavior проверяется отдельно. Canonical SDK metadata
может читаться из физического пути, содержащего буквальный macro-like текст.

Generator кодирует доллары только в собственных literal paths перед записью
PBX references и build settings; authored expressions остаются expressions.
Filesystem readers generated paths, ODR tagging и relocation учитывают это
кодирование. Ownership IDs consumer xcconfig соответствуют сохранённому path.
Исключения resources различают абсолютные filesystem paths и generated product
expressions: $(BUILD_DIR) и $(BUILT_PRODUCTS_DIR) в последних сохраняются.
Полный configuration suite выявил ошибку blanket escaping такого product path;
постоянная regression отдельно проверяет literal direct file и conditional bundle
в Debug/Release, offline reinstall и deintegration. Оба вида исключений проверяются
по сохранённому graph и по фактическим ресурсам собранного приложения.
Постоянные tests проверяют offline reinstall, init, двойную deintegration,
relocation, Xcode comparisons и реальные Debug/Release consumers. Runtime
observations modifiers сохранены отдельно от реализации; baseline Sources и
финальные тесты используются для доказательства исходных failures.

Модель сверена с первичными источниками: [Swift Build macro evaluation](https://github.com/swiftlang/swift-build/blob/main/SwiftBuild.docc/Core/macro-evaluation.md)
и [Apple build-setting examples](https://developer.apple.com/videos/play/wwdc2021/10210/?time=738).
Standalone Xcode control без SwiftPods подтверждает повторное раскрытие
literal CONFIGURATION в собственных linker search directories и предупреждения.
Исходное имя сравнивается без overrides; executable fixture задаёт безопасный
CONFIGURATION product folder. Warnings policy не ослаблена; произвольные builds
с такими names не считаются доказанными.
Upstream main может опережать выбранный runtime: например, truncatedversion
в проверенной версии Xcode не преобразует operand. Literal includes и настоящие
variable cycles сохраняют свои прежние ограничения и diagnostics.

Повторный аудит определений исправляет ложные cycles в именованном наследовании:
ссылка на активную переменную берёт её предыдущее определение, в том числе через
другие переменные. Результат зависит от стека определений и не кэшируется только
по имени. SDKROOT может наследовать global default macOS; отсутствующая raw
переменная при этом не появляется. Предварительные SDK guesses допускают ещё
не загруженное определение из base file, project/target scope или condition;
полная оценка по-прежнему диагностирует настоящие cycles. Отдельный reader
xcconfig использует то же предыдущее SDK-определение. Старый negative fixture
заменён настоящим custom-variable cycle: прежний SDKROOT ↔ FIRST допустим в Xcode
из-за global default и проверяется теперь как положительный случай.

PBX file expressions вычисляются анонимно: имя внутреннего temporary binding
больше не попадает в authored namespace. Неизвестное short $NAME остаётся
буквальным, что проверяется отдельно от bracketed references. Неопределённый SDK
с подходящим префиксом не выбирает платформу; SDKROOT с NUL, включая indirect
значение, отклоняется до hooks/managed writes при explicit и implicit platform.
Бинарные PBX fixtures защищают именно эту проверку. Xcode при NUL аварийно
завершался в отдельной диагностике; постоянный тест не повторяет его crash.

PODS_* scalar paths учитывают чётность обратных слешей перед долларом. PBX
string paths сохраняют отдельное кодирование. Header lookup использует string
form при обратном слеше в корне. Старые raw generated xcconfig references
нормализуются как при analysis, так и при открытии graph для hooks; original
root и существующие support files предотвращают двойное декодирование долларов.
Нормализация сохраняет ownership и перестаёт подтверждать его после постороннего
изменения path. Upgrade corpus проверяет доллары в root и configuration filename,
offline byte stability и двойную deintegration с восстановлением исходного graph.

Независимый Xcode project без SwiftPods воспроизводит потерю обратного слеша
в compiler response argument. Executable fixtures с такими roots задают
CLANG_USE_RESPONSE_FILE=NO и выполняют приложения Debug/Release. Это внешняя
граница Xcode/LLVM: настройка применяется только к тестовой команде, не пишется
в пользовательский проект и не отключает warnings-as-errors. Default response
control сохраняет фактический статус, чтобы исправление будущего toolchain
не превращалось в ложную regression. Семантика definition ancestry и escaping
сверена с указанным выше первичным Swift Build source и установленным Xcode.

Следующий проход подтверждает потерю SDK conditions через scalar declarations,
которых не было в прежнем коротком списке типов: PRODUCT_NAME, SYMROOT,
INFOPLIST_FILE, MODULEMAP_FILE, compiler enums и signing fields. Xcode раскрывает
SDK\$(SUFFIX) как строку, неизвестная пользовательская переменная сохраняет
list escaping. Типы Options/Properties читаются из выбранного Xcode; контекст
DEVELOPER_DIR и namespace сохраняются во всех слоях оценки. Untyped option
наследует известный тип либо получает String default. Конфликтующие и неизвестные
типы диагностируются при использовании. Отдельные unit fixtures проверяют
изолированные installations и передачу namespace через project/target/file scopes.
Массивы проверены отдельными runtime controls: установленный project boundary
ведёт себя согласованно с текущим coercion, поэтому upstream generic parser
не стал основанием для неподтверждённого изменения поведения.

Восстановление generated xcconfig больше не выбирает путь по существованию
соседнего файла. Случай с Debug-$Cash и Debug-$$Cash воспроизводил ложный конфликт
Swift versions 5.0/99.0, когда один support file отсутствовал. Удаление обоих
файлов позволяло install пройти, что изолировало ошибку идентичности. Формат
современных references отмечается в receipt; legacy identity определяется по
physical file ID или target/configuration metadata сохранённого Pods project.
Если данные producer отсутствуют, сохраняется обычная семантика PBX expression.
Неподтверждённый сосед не подменяет отсутствующий generated file. Неизвестная
версия encoding отклоняется до hooks/managed changes. Permanent corpus проверяет
legacy raw и escaped spellings, random UUIDs, relocation, отсутствие Pods project,
соседа с другим количеством долларов и восстановление после поддержанных metadata.

Первичный источник типов — [Swift Build macro namespaces](https://github.com/swiftlang/swift-build/blob/main/Sources/SWBMacro/MacroNamespace.swift)
и [build option declarations](https://github.com/swiftlang/swift-build/blob/main/Sources/SWBCore/SpecImplementations/PropertyDomainSpec.swift).
Семантика дополнительно сравнена с установленным Xcode, включая фактические
Debug/Release outputs. Неуспешные попытки и исходные baseline sources сохраняются.

Фактические команды, ревизия, source/contract digests, toolchain, отчёты и logs
записываются текущим запуском `scripts/check.py`. Неизменённые старые отчёты
не считаются результатом нового кода. Проверки проекта и собираемых приложений
дополняют unit/DSL tests; успешный парсинг сам по себе не доказывает сборку.

Аудит не является доказательством отсутствия всех возможных ошибок.
Signing/notarization, физические устройства, Intel, минимальная macOS,
чистая Homebrew-установка и остальные внешние gates требуют своей приёмки.
Они не получают статус `passed` из результата локального рефакторинга.
