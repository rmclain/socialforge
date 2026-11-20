import Foundation

/// The reference CSV for posting a folder of images, each with its own link.
///
/// The app saves it (File › Save Sample CSV…) and the repository keeps the same
/// text in docs/samples/media-links.csv; a test fails if the two drift.
public enum SampleCSV {
    public static let filename = "media-links.csv"

    /// One row per image. `filename` matches the image's file name, ignoring
    /// case and extension. `url` is where the post links to. The other columns
    /// are optional and fill the post's title, description, and alt text.
    public static let text = """
    filename,url,title,description,alt_text
    walnut-cutting-board.jpg,https://example.com/products/walnut-cutting-board,Walnut Cutting Board,"End-grain walnut, oiled by hand. Made to last a lifetime.",A walnut cutting board on a kitchen counter
    linen-apron.jpg,https://example.com/products/linen-apron,Linen Apron,Stonewashed linen with deep pockets and cross-back straps.,A sand-colored linen apron hanging on a hook
    ceramic-mug.png,https://example.com/products/ceramic-mug?utm_source=pinterest,Speckled Ceramic Mug,"Wheel-thrown stoneware, 12 oz. Dishwasher safe.",A speckled ceramic mug filled with coffee

    """
}
