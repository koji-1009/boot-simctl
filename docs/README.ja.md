# boot-simctl

[![CI](https://github.com/koji-1009/boot-simctl/actions/workflows/ci.yml/badge.svg)](https://github.com/koji-1009/boot-simctl/actions/workflows/ci.yml)

GitHub Actions で iPhone / iPad / Apple TV / Apple Watch のシミュレーターを起動する composite action です。中身は POSIX シェルスクリプト 1 本で、`xcrun simctl` を呼び、`plutil` と POSIX の `sed` / `awk` / `sort` / `ps` を使います。

*The English version is at [README.md](../README.md).*

```yaml
- uses: koji-1009/boot-simctl@v1.1.0
  with:
    device: iPhone
    os: '26.1'

- run: flutter test integration_test/app_test.dart -d "$SIMULATOR_UDID"

- if: always()
  uses: koji-1009/boot-simctl/shutdown@v1.1.0
```

起動したデバイスは `SIMULATOR_UDID` としてジョブの残りに公開されます。ツールがデバイスを要求したらこれを渡してください。シミュレーターの名前は `ci-simulator` なので、`flutter test -d iPhone` では見つかりません。

`actions/checkout` は不要です。action 自身がスクリプトを持っています。

## 入力

action は薄いラッパーなので、各入力はスクリプトのオプション 1 つに対応します。

| 入力 | オプション | 既定値 | 説明 |
| --- | --- | --- | --- |
| `device` | `--device` | `iPhone` | `iPhone` / `iPad` / `tv` / `watch` / `vision`。機種名の指定時は無視 |
| `os` | `--os` | 指定なし | その系列の OS バージョンの要求（下記） |
| `xcode-version` | `--xcode` | 選択中のもの | 先に選ぶ Xcode。構文は `os` と同じ。ジョブの残りにも効く `DEVELOPER_DIR` を設定する |
| `model` | `--model` | なし | 機種名を直接指定する。`device` より優先 |

スクリプトにはこのほかに `--dry-run` があり、絞り込んだリストを表示して終了します。

`shutdown` action はデバイスを停止して削除します。既定でこのジョブが起動したものを対象にするので、通常は入力が要りません。別のものを指定したい場合は `udid` を渡します。**composite action は post ステップを登録できない**ため、後片付けは自分で書くステップになります。

## スクリプトを直接使う

```sh
boot-simctl boot [options]
boot-simctl shutdown <udid-or-name>
boot-simctl list [runtimes|devicetypes|devices|candidates|xcodes]
```

起動に成功すると UDID を標準出力に 1 行だけ出します。診断ログはすべて標準エラーに出るので、`udid=$(./boot-simctl boot ...)` がそのまま使えます。

## デバイスの選び方

action とスクリプトで共通の挙動です。上の入力は下のオプションと 1 対 1 に対応します。

このマシンで実際に動かせる「OS バージョン × 機種」の組み合わせをすべて 1 本のリストにまとめ、指定したオプションで順に絞り込み、**残った先頭**を採用します。リストは新しい OS が先、同じバージョンの中では Xcode 自身が並べる順（新しい機種が先）です。

| 指定 | 選ばれるもの |
| --- | --- |
| （なし） | 最新 iOS の最新 iPhone |
| `--device iPad` | 最新 iOS の最新 iPad |
| `--device watch` | 最新 watchOS の最新 Apple Watch |
| `--os 26.1` | 26.1.x のうち最新の、その最新 iPhone |
| `--os 26.1 --model "iPhone 17"` | ちょうどその組み合わせ |

`--model` を指定すると `--device` は無視されます。機種名だけを指定した場合は、その機種が動く最新の iOS が選ばれます。

リストの中身は `list candidates` で確認できます。`--dry-run` を付けると、絞り込んだ結果を採用される 1 件を先頭にして表示するだけで、作成も起動もしません。どちらも同じタブ区切りの列を出すので、`cut -f4` などがそのまま使えます。

```
$ ./boot-simctl boot --device iPad --os '>=26' --dry-run
26.5	…SimRuntime.iOS-26-5	iPad	iPad Pro 13-inch (M5) (16GB)	…SimDeviceType.iPad-Pro-13-inch-M5-16GB
26.5	…SimRuntime.iOS-26-5	iPad	iPad Pro 13-inch (M5)	…SimDeviceType.iPad-Pro-13-inch-M5-12GB
…
```

リストには CoreSimulator が実際に受け付ける組み合わせしか入りません。「iPhone 17 を iOS 18.6 で」のような成立しない組み合わせは最初から現れないので、指定したバージョンに存在しない機種を要求して失敗することがありません。

絞り込みで候補が空になったときは、どの条件で消えたかを表示します。

```
$ ./boot-simctl boot --os 26.1
boot-simctl: available OS versions:
  26.5
  18.6
boot-simctl: no OS version satisfies '26.1'
```

### バージョン指定

`--os` は前方一致と比較のどちらかを受け付けます。空白区切りで複数書くと AND になります。

| 指定 | 意味 |
| --- | --- |
| `26` | 26.x.y のいずれか |
| `26.1` | 26.1.x のいずれか |
| `26.1.1` | 26.1.1 のみ |
| `>=26.1` | 26.1.0 以上 |
| `<26.5` | 26.5 未満 |
| `">=26.0 <26.5"` | 両方を満たすもの |

`>` `<` `>=` `<=` が使えます。前方一致はドット境界を守ります。`2` は 26.5 に一致せず、`26.1` は 26.10 に一致しません。

`^` と `~` はありません。前方一致が `~` と同じ意味を持つためです。`26.1` はちょうど `>=26.1.0 <26.2` にあたります。

3 成分のバージョンは知っておく価値があります。Xcode は実体が 26.4.1 のランタイムも `iOS 26.4` としか表示しないため、ランナーが「表示されるどこにも現れないバージョン」を積んでいることがあります。ここでは `--os 26.4.1` と `--os 26.4.0` は別のものを選び、`--os 26.4` はどちらも受け付けます。

## CI での注意点

シミュレーターは毎回 `simctl create` で新規に作るので、状態は常にクリーンです。`simctl erase` は要りません。同名のシミュレーターが残っていれば起動前に削除するので、前回のジョブの残骸があっても壊れません。

使えるランタイムは選択中の Xcode によって変わるため、`xcode-version` が最初に処理され、ジョブの残りは `DEVELOPER_DIR` 経由でそれを引き継ぎます。`sudo` も `xcode-select` も使いません。

```yaml
- uses: koji-1009/boot-simctl@v1.1.0
  with:
    xcode-version: '26.5'
    os: '26'
```

バージョンはパス名ではなく各バンドルの `version.plist` から読むので、ランナーが `/Applications/Xcode*.app` にどんな名前を付けていても影響を受けません。導入済みのものは `list xcodes` で確認できます。

ランナーに目的のランタイムが入っていない場合は、`xcodebuild -downloadPlatform iOS -buildVersion 26.1` で追加できます。数 GB のダウンロードを伴います。

## テスト

```sh
./test/test.sh          # 選択ロジックと引数処理（数秒）
./test/test.sh --all    # 実際にシミュレーターを起動する分も含む（数分）
```

## 制限

シミュレーターは常に `ci-simulator` という名前で作成し、shutdown で必ず削除します。CI 用の使い捨てを前提にしているので、その名前に意味があるマシンでは実行しないでください。

`vision` も受け付けますが未検証です。GitHub のランナーに visionOS ランタイムが入っていないためです。
