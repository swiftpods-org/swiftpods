class Swiftpods < Formula
  desc "Dependency manager for Apple platform projects"
  homepage "https://swiftpods.org"
  if Hardware::CPU.arm?
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.3.8/swiftpods-0.3.8-macos-13.0-arm64.zip"
    sha256 "f1d6c5a3643ffa2e429c167b11224d9a9807bbb93ea947a65b1d2b906fccce06"
  else
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.3.8/swiftpods-0.3.8-macos-13.0-x86_64.zip"
    sha256 "55ad96685d61891846fec795f1c8fd4e6f6acfefcbd38a1b8b4ccdb9621720df"
  end
  version "0.3.8"
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
