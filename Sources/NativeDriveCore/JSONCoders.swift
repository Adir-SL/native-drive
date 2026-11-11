import Foundation

public enum JSONCoders {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(DriveDate.format(date))
        }
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = DriveDate.parse(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date \(text)")
            }
            return date
        }
        return decoder
    }
}
