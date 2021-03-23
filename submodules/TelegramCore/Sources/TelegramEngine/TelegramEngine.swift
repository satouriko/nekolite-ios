import SwiftSignalKit
import Postbox

public final class TelegramEngine {
    public let account: Account

    public init(account: Account) {
        self.account = account
    }

    public lazy var secureId: SecureId = {
        return SecureId(account: self.account)
    }()

    public lazy var peersNearby: PeersNearby = {
        return PeersNearby(account: self.account)
    }()
}
