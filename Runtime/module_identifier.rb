# frozen_string_literal: true

module SwiftPods
  # Keep identifier projection identical to the native generator.
  module ModuleIdentifier
    LETTERS = {
      "A" => "ÀÁÂÃÄÅĀĂĄ",
      "AE" => "Æ",
      "C" => "ÇĆĈĊČ",
      "D" => "ÐĎĐ",
      "E" => "ÈÉÊËĒĔĖĘĚ",
      "G" => "ĜĞĠĢ",
      "H" => "ĤĦ",
      "I" => "ÌÍÎÏĨĪĬĮİ",
      "IJ" => "Ĳ",
      "J" => "Ĵ",
      "K" => "Ķ",
      "L" => "ĹĻĽĿŁ",
      "N" => "ÑŃŅŇ",
      "NG" => "Ŋ",
      "O" => "ÒÓÔÕÖØŌŎŐǪǬ",
      "OE" => "Œ",
      "R" => "ŔŖŘ",
      "S" => "ŚŜŞŠ",
      "SS" => "ẞ",
      "T" => "ŢŤŦ",
      "Th" => "Þ",
      "U" => "ÙÚÛÜŨŪŬŮŰŲ",
      "W" => "Ŵ",
      "Y" => "ÝŶŸ",
      "Z" => "ŹŻŽ",
      "a" => "àáâãäåāăą",
      "ae" => "æ",
      "c" => "çćĉċč",
      "d" => "ðďđ",
      "e" => "èéêëēĕėęě",
      "g" => "ĝğġģ",
      "h" => "ĥħ",
      "i" => "ìíîïĩīĭįı",
      "ij" => "ĳ",
      "j" => "ĵ",
      "k" => "ķĸ",
      "l" => "ĺļľŀł",
      "n" => "ñńņň",
      "'n" => "ŉ",
      "ng" => "ŋ",
      "o" => "òóôõöøōŏőǫǭ",
      "oe" => "œ",
      "r" => "ŕŗř",
      "s" => "śŝşš",
      "ss" => "ß",
      "t" => "ţťŧ",
      "th" => "þ",
      "u" => "ùúûüũūŭůűų",
      "w" => "ŵ",
      "x" => "×",
      "y" => "ýÿŷ",
      "z" => "źżž",
    }.flat_map { |ascii, characters| characters.each_char.map { |letter| [letter, ascii] } }.to_h.freeze

    def self.normalize(value)
      value.each_char.map { |letter| letter.ascii_only? ? letter : LETTERS.fetch(letter, "_") }.join
        .gsub(/[^a-zA-Z0-9_]/, "_").sub(/\A(?=[0-9])/, "_").gsub(/_+/, "_")
    end
  end
end
