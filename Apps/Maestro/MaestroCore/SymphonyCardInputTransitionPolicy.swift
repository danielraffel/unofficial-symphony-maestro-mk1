import Foundation

/// The route policy at the 64↔32 boundary. Unit-B RX slots are valid only
/// while 64 channels are running; a 32-channel transition therefore replaces
/// every lower-half B reference with the saved single-unit route, or identity.
public enum SymphonyCardInputTransitionPolicy {
    public static func restoreSingleUnitRoutes(_ routes: [Int: Int], count: Int = 32) -> [Int: Int] {
        var result = routes
        for host in 0..<count where (32..<64).contains(result[host] ?? host) { result[host] = host }
        return result
    }

    public static func restoreSingleUnitRoutes(_ routes: [Int: Int]?, count: Int = 32) -> [Int: Int] {
        restoreSingleUnitRoutes(routes ?? [:], count: count)
    }
}
