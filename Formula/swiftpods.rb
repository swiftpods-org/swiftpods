class Swiftpods < Formula
  desc "Dependency manager for Apple platform projects"
  homepage "https://swiftpods.org"
  if Hardware::CPU.arm?
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.3.17/swiftpods-0.3.17-macos-13.0-arm64.zip"
    sha256 "2107f12fd63299cd1a190daacc6e26556cf14ac448da685630344e261d24e96e"
  else
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.3.17/swiftpods-0.3.17-macos-13.0-x86_64.zip"
    sha256 "31526144352c27f85e5ce17a1aa26609f5c1e5dfca83e828b50163d17eb179d3"
  end
  version "0.3.17"
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
