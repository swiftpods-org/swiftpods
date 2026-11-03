class Swiftpods < Formula
  desc "Dependency manager for Apple platform projects"
  homepage "https://swiftpods.org"
  if Hardware::CPU.arm?
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.3.10/swiftpods-0.3.10-macos-13.0-arm64.zip"
    sha256 "472db733ba822500a2bc8c63ec7c3f2e2bd7b9671498a33995d53e6d5d686723"
  else
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.3.10/swiftpods-0.3.10-macos-13.0-x86_64.zip"
    sha256 "30dacf89537c310ced4982847741aacde351acee8c4d7f3157fc5dd189723c08"
  end
  version "0.3.10"
  license "MIT"

  depends_on :macos

  def install
    minimum = { "arm64" => "13.0", "x86_64" => "13.0" }
    architecture = Hardware::CPU.arm? ? "arm64" : "x86_64"
    odie "No release for this architecture" unless minimum.key?(architecture)
    odie "Requires macOS #{minimum.fetch(architecture)} or newer" if MacOS.version < minimum.fetch(architecture)
    bin.install "bin/swiftpods"
    prefix.install "LICENSE", "README.md"
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/swiftpods version").strip
  end
end
