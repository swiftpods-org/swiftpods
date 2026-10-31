class Swiftpods < Formula
  desc "Dependency manager for Apple platform projects"
  homepage "https://swiftpods.org"
  if Hardware::CPU.arm?
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.3.1/swiftpods-0.3.1-macos-13.0-arm64.zip"
    sha256 "c25b0ce67d716327996586e8759c0b539e90e939b68f18f167cc1e869b6be52c"
  else
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.3.1/swiftpods-0.3.1-macos-13.0-x86_64.zip"
    sha256 "4475b5c8fc02f0dbb88d16ec227fd566cdc52d639520f7b1480fcd3867b13819"
  end
  version "0.3.1"
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
