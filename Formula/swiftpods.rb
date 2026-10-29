class Swiftpods < Formula
  desc "Dependency manager for Apple platform projects"
  homepage "https://swiftpods.org"
  if Hardware::CPU.arm?
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.2.1/swiftpods-0.2.1-macos-13.0-arm64.zip"
    sha256 "74b15cfe294c35cef29aff2a27da4984672ac06148715eee0b7ac5e4327e2cb6"
  else
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.2.1/swiftpods-0.2.1-macos-13.0-x86_64.zip"
    sha256 "4566bbceafe85654033d15becae92811359ad04240c5da4a38eccc1f59df0304"
  end
  version "0.2.1"
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
