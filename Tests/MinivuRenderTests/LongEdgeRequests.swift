import Foundation
@testable import MinivuRender
import MinivuCore

// Plain long-edge requests, which the tests here are written in: a square
// view gives its side as the long edge whatever the image's aspect. The app
// asks for the image fitted into its real view size.

extension ImageLoader {
    @discardableResult
    func load(_ entry: FolderEntry, page: Int = 0, pixelSize: Int,
              update: @escaping (Result<ImageTexture, Error>) -> Void) -> LoadHandle {
        load(entry, page: page, fitting: CGSize(width: pixelSize, height: pixelSize), update: update)
    }

    func prefetch(_ entries: [FolderEntry], pixelSize: Int) {
        prefetch(pages: entries.map { ($0, 0) }, fitting: CGSize(width: pixelSize, height: pixelSize))
    }
}

extension TextureCache {
    func bestTexture(url: URL, modified: Date, page: Int, minimumLongEdge: Int) -> ImageTexture? {
        bestTexture(url: url, modified: modified, page: page,
                    fitting: CGSize(width: minimumLongEdge, height: minimumLongEdge))
    }
}
