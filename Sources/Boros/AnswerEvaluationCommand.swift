import Foundation
import CoreFoundation
import Darwin
import CSQLite

/// Unregistered public-development diagnostic. Oracle fields and existing
/// stores are deliberately absent from this interface. Answers leave the
/// runner only in private, separately named transient scorer IPC files.
enum AnswerEvaluationCommand {
    /// Exact oracle-free projection of evaluation_fixtures.generate(
    /// "development", history_count=1) through evaluate_answers.runner_input.
    /// Updating this pin requires an explicit diagnostic source amendment.
    static let publicCorpusProjectionSHA256 = "6ca035c6bb87f23b75c59c8529a0181667e8ece0cc838056139d009f0c501bb4"
    /// N3 source amendment: three exact oracle-free DevGPT projections. This
    /// remains an allowlist, never a general arbitrary-history interface.
    static let developerCorpusProjectionSHA256: Set<String> = [
        "3ce6a107744a380f2b1f047bbfcacae380bb396cc14cc23c8108d8c240d1d091",
        "9d2a765385191a91562e52312ad906338aba99c7cf46aa144497e7b7047fff41",
        "0ac2f9963c690db4365792fbd2f0f82dfc0929baf15df535caa41f29bef9bd38"
    ]
    /// Separately frozen full-exchange witness projections. Version one never
    /// accepts these packs or supplies witness selection to retrieval arms.
    static let witnessCorpusProjectionSHA256: Set<String> = [
        "ae74877c63469436c0e8e17c16f9f4098eeee06e34f5a52f68ddaf8ae0f32aee",
        "5dd12260c9eaedf39965285cdb1d0cd821bde4d8a3ce53d67546854dc06b950a",
        "f9846f813421e252690662e0e0f2c937d129b2d92725c4f8d0557448b2aee207",
        "6f3c01af22d0069091fffb571686fb2acea7ed25475fe1dcf3fdd94808f3567d",
        "01918c47e143c6c21288dc3302fc2d36cb3a98064625aa2b659eb8d23f39953d",
        "5c6002a0f86505e7c9b3d0aaef421c450bea49febf6ee3822c7d3f88662ad67f",
        "f3c2b62c221401c941fedd72aa288cd22868c3a259136bf45965b3670a49e787",
        "7a324ac5081b76309a2ba1667fd38a234ad55011382f6afe5cc335f4f7db96c4",
        "5ee1706bcc661fa306758e546a24c0c894f616ca5d07972ddb5e5f4ba0a7d0e1"
    ]
    // Foundation's canonical numeric zero is 0; the Python source pin retains
    // 0.0. Both representations describe the same frozen configuration.
    static let witnessConfigurationSHA256 = "73729124226e2a729d052ea49d6f03ecced31b2b93e3beea63064ab046fa0013"
    /// Separate system-only development amendment; original settings and
    /// projection pins remain accepted exactly as declared.
    static let formatInstructionConfigurationSHA256 = "f13e87eb29ce2ecf88746293d3f01d74841394dc0a0aca3d2e9d5747dda53361"
    static let jsonObjectConfigurationSHA256 = "8aef45d2a8c7d20b8ee669606df5094f9d4ec960f82496841e8680dd433167cd"
    static let jsonObjectCorpusProjectionSHA256: Set<String> = [
        "7eaa4b959959b0afcb5f9895634e552eae1bac062e3100ab1f0d2d8d2653bdcb",
        "ab841b6f5611ed3df034b384ec440a23c46e9968ffecf61482eea572dce97ade",
        "52150ae4979989ebf12a9628a6ad0aecd2960150f5b15e897c85c0ba2d02c32e",
        "42cdff1f9aa72c7b2c7ce8724d26c6397038b9288e354cb5f1346b5d80e2f790",
        "fa40c8a36239be193de2f88bc80b10ef54a1eb1b476b9d8fad58ff8d2d9fb2b7",
        "eaa7aa2b33c5c51acbb42f805e82709ff7409a72acaa36702cdcc5c66770a835",
        "5238c51f6ec58ad3908a3654ae0fbe1f0a373dd13bec9ff040338459cb138218",
        "09316ffa9fc3f26d2dc81acad2eb7ede0c1c1c9b12dd678e6c80d38ed9c8230c",
        "eedf2f3ca33017e90b1ad449be99ef50bddba4f792b5f9635f44001151cbccdb"
    ]
    /// Original version-4 LongMemEval S development projections; no oracle labels.
    static let longMemoryCorpusProjectionSHA256: Set<String> = [
        "87dcca85d2aaf4c1e5db21efbf466bed20b3673477698ff8a2e9b8adbdc9c32c",
        "5015ce3363b4f540b1eb2e7ec2ce398366e5a5d8253a6da40e63e10cd200c908",
        "9ee0a2ee042f99e87cdd82e5313c1a033c0880ad1d98bcbc1175ee05001f5dbd",
        "6bc8af5c9058844422d2a43b4640b85c50d43d470d33ea86a90f40ae7c7458a1",
        "cc2fbe2a44c6a0db7431044e67af686f80af7ec4fa8a7820cb2075711eb963e1",
        "d0a768245614fcf955266240969c66038f6d132b332ad24661413755982babb1",
        "1b1416dee0c4e8bb4508d6d5e4d9af10896d5ca68f8656b5a1a45888768f432f"
    ]
    /// Separate semantic-question-range diagnostic; v4 pins retain full semantic input.
    static let semanticLongMemoryCorpusProjectionSHA256: Set<String> = [
        "09f442d458c695c364fdf45baa8f5d09c62d1e21c87f808dd86ebd2c6a0f373f",
        "3dd2d9e759656b04864c5d1bf4428ceafd0f20e552e9eb29a7a24cfd9169cdf5",
        "86fa124c67072f1012281c2e5fecc70b04f92b45462054dbac91e1e1d614b33e",
        "d8cfdc15fa97415ceddb5e85d8ab024f2d221e194c64bfe8d1af1014fdf28c81",
        "249e4ac7527dc33ac6a0b236eaac5325297bb9b84e29c09473c0e491f2fd4cf1",
        "249fbf4665249094d99cfda40f34bb12308bb5e5e42ca809e0bc61901a70ec0c",
        "689e8a129f3aff322d11fc6ea455b88d75cd95c1d23e1012d0ccb3279593901b"
    ]
    /// Separately pinned complete-original-source delivery controls. These
    /// declarations do not assert that the selected sources answer a question.
    static let completeSourceLongMemoryCorpusProjectionSHA256: Set<String> = [
        "fe6e8f3f0f46ab3cd1396552d14a6fad3e3ff6ba8dc79237318f07cedc9ff88f",
        "4cfe6f614ee53b8884d7976fb07d33c1c84291c13fdcd3b51e9c74f736188909",
        "147b22015fb585e5dfe5f16aa83bd00d6a78d1025ac284a689c4d87afbe066bf",
        "617cc682749008ee32ce7f2ecddc06bd900cb2de933312295de11bc7d170af40",
        "d7a5dbeb84cb541483728498fa80912120be549ac67d7dba3d635a40e747de29",
        "3bec8104d1c60064cd378b304754e876ad0891470e20c4679df0e21bda36e0a3"
    ]
    static let longMemoryConfigurationSHA256 = "c23bf5d0bb63e7a348adfc4f673c9c01a1217d89e4c9e51c61f9bf80a300cf21"
    /// Independent development cohort: original histories and paired ordinary
    /// strategies, separately pinned from the reused v4-v6 diagnostic cases.
    static let independentLongMemoryCorpusProjectionSHA256: Set<String> = [
        "4aad7cb5d65069b853c6852bca223049020417ecae799344a9ff579600c469e8",
        "877999e49027c2d1801da2072dffdfc1b625dc1cc90f3954909d78a91fb95d7d",
        "d34354e4d795f92a65535b1b4c7038f0917772790263b3466aa7e3ee4da822e1",
        "e43a5d27f41961f8aae69bdab5858cea1ede19e1d0d7a30e5d37c3a315081942",
        "d7768d3ae9538f26a6d377d3351448e432f821d22df79ee99521c0fa3c907b76",
        "d522f012e5ec259dc6154934462cc96c5a131a0d68a06b83d504d66db5f85a04",
        "adfa18a04185021306d5a7602fa81f74b32402506cf8d6b1cc0fbaa8e247f48f",
        "9263f9f93c02b4764b8c7ca78251627abf95ad2100c4cb5262a665562825457f",
        "5f0a5b74a478f640e55971f48d2f7f91270bf79a05496832722cc3a7b0f847a8",
        "baf71a226fb86f2e515a30d863ac1e408e84fee183987eef5e928c8edf9f1999",
        "98983bd7eaaad4e48c182293adb8dcc66900d9eb472841750f6b665733aeffeb",
        "205a6863707939eb00720a72c7166d3ae98720190275a2425ef589ae538b92d9",
        "b276edab0ad6cfc4e27f3c4834f6f4dd3375049d7a053cf591e4f7bb1d7af314",
        "853e68bd253f3ae19612131600b16a86c37dff639c555aa510efa3c6752c3780"
    ]
    static let independentLongMemoryConfigurationSHA256 = "59dee690589e35b394ea40b6adfbf4bde36aacb349912abb0e94a09aebbefe07"
    /// Separately frozen 100-question, single-investigation projections. All
    /// model-visible identities are opaque; annotations remain scorer-only.
    static let hundredLongMemoryCorpusProjectionSHA256: Set<String> = [
        "2306e233f42ea2c9499731491c2cb3126beecd7ea75d2e9b3cf2c99a81750477",
        "87c07140cb577da40eef6d3e5529007c264133d5d9e8eb51899b6042dd0aef22",
        "ebf76985c9d887c5cc2f9804a93218f8c7607ea4e74b76001ae013a85c300c4f",
        "62e2f02168af8ec44ceed7306fcb5f43742020532e26f755b4b34f5fe1d5faf2",
        "de1b49c58f212f378d42bd33d202189eb9f6cd162995b14136b7c2ba334a0423",
        "caf3b3b438243f2ca177df54d3bebc9bb82db52538aa8924335b52aad4234cfd",
        "43508938411c73bc839c1ae504b49674c37ba501df54d3929798310de354ea64",
        "75da9cf555be112d94d8b7301f6667e95cdabdd48f8ceee67cae4b86c5f7a7d5",
        "9ec0250544a8d6e6b5456cfb8713090cefd98b800da26d9efa83166d70406241",
        "6219b502a7497b510f7bb79189b5a6303489b2ea23703d35ba9552d7ce35c046",
        "17408156239b0acc6df6f68e075f92b6b6ede8b84e5996a54f2e5179960348c4",
        "ce62c00bcd7c954970a9aebecc7baf1168e8b83121a5ebc706e291083cb6110c",
        "a4ed285d18737de7554a7953f247b434920c35fb7198017258df7c8eb0978636",
        "e43511b1789a2ef63d3cc78110febc613014e4d57deeaa7c8d34583aa409f2c0",
        "2bbfd8f56ecbd10cb713a176a1328c9e1f84382d9e9473e206e7fb084ba17516",
        "2705b896bcdcbb197ff2f931015487d504ee1a0a93a5e1c8f6f0a42918e7f822",
        "2a1141d5a11bb7843e4dba177c3105b0df89e531d81ea92396dab8327f49bd7d",
        "7d7cf52d0d090b0fe2d22098af33f0058128c9dfc1db6c1ca31ce086fee49cdb",
        "0d4c268559e9b5d39dee2686653c92584e9d633eb179a44a92e4148e44f5aeb4",
        "5a4b6db45956844fd246c8f14a897ec8fa5f560a1a8f539b1874b5a4dfa0fea2",
        "9797f5b8c395acb01b5027e4a54834afd298c1211854672411df615d2981689d",
        "e42e06599167951c5084b3c3217cd0072523cb1d698cb8d5843e0d59d64cf6a0",
        "c344d50823eac46dd8635919b62a8fd25e27a69969b66a7930465634182c3559",
        "4a6383f812f86f76ecff1220a87930dc041e2d770cfc896c24999b43fe0496f9",
        "fa2783afeff427575b4020496cc15e197f8e71a198e5db34f7716b7d0fa46afd",
        "9e425c755a21b09c8594ba5a65323c3e702c139bbb2cb458cf623a7804e4f3bc",
        "308083460f9c020247de6b323dfa9ac6e53bc4753e255d3c7ca757a248a3576e",
        "332611112e58b42b0d7412a95bd3aa365539f71d8649cf4479be5b5cd7efdb6b",
        "de1a1868543cb455525f21ececb45df73303e7062c2b78e6f87fe4663c124073",
        "6a46834e3c5b01d23f12ff37fd99802347f2aaba1dcf303b1e95dcdeaebdb481",
        "8e7ceb3e0acf2f690e24a8f141dbab2669d35c58461767da6ecb277d5e4bdda4",
        "e994c2a6f22cc5a554101aecfb67273635106b275ee2030d752a6b226b81cf06",
        "bc0a77022635c0394a2c74aa58cefd43b5d664f8c45f2b10512504bab8e393f6",
        "bdb54d7071f62cb109a9d7a98e6e6d7995768cc316269ca3a974462d6dac5b2c",
        "31310e8252cf0140624f359cbdaea8a0f0f84184bc2a16b9224199f8c0542f86",
        "391331ddbce1063dfdd0139c9c0ae8c39fd1572c6e531388317a2b4b5c64e917",
        "e82f9fb496569626088c5551efd595301117853549a2b311f4567272ec4a7184",
        "e8ce7245692e4d0e033ecfa2f4e5ede8ee65e3c721701a0c64860f1f9a8ddda0",
        "e793aab36e331bf639423cb589e0d3af212a798d8d8a83aac14e25f252d420f1",
        "ac07131b74205c19bab769688e2cd262e551ac88be6e3e7049f71355992fedc2",
        "ed59ea60390f85452f4a878d44f1d56e052623dfe1bd18f88c6ac27ebbf1af63",
        "0a9cf123f493b50cc89791550e955a828dfb9f798823bded91998b3145e97c3c",
        "e1e8753d9530e5129f3a85d96ad0b8a422d49b7e4be35ce1fda275d12677e651",
        "1567227b554ad6c1c48a551b93102336eaa7237d9c2cb779773baf9622cbda69",
        "01cf272af6df035922fb0234c894741731d41fb1349e4668cd77ea71a216cfd3",
        "51eba20694b4f6cf5b2141b1294a4ec4488219f1759dd2e9a2ce011c5c880920",
        "78b08e77be87fc556da33eab4b8df7cb310865c719b918857266771cce9a891c",
        "805eb06dc24b7594a4886a0e4f3e3e1b248bbe669afea197726251e20a24015d",
        "18b053634a1dac576166a0bcc57dbaf32720b9d17bc0acf93a1c639ca02ce968",
        "e78a9e550169e479aad524ad55948a502e2c8f960e56a41dad72f2cb739dc227",
        "5cb89a79214b918a698373f810a547b51b24595da3751487fe723da1d8925afc",
        "b2b47e5392e266e5826be6fe424ef10ce0f2da8bc28464e96613eaa4499eabdb",
        "093babc22f84a998986ff841a5c807494d378edbe049ab2ce70e539aa47a60a9",
        "1b9701fa5c394479d4bc9c87ec06c9acb5f562b415b5b3822840326199ab10ba",
        "325b33a2f8f2ab1f084c337d652123ecfa0c60bbdd3801e68ffca18e5fec6bad",
        "f536df55d03d1b7d4b35e44c63c54b87e44acbd10e2fe6642dd4707c43a970d0",
        "08186aacb3db34592e32d2be235f45862562c5ee88976c586fed3c99ca8ed16a",
        "d4fa316abaea6c2ffaf9214be4fcd8df37602ec8bc44471fe2a6c6a9b2947dc8",
        "cf99f295f3da787dc26e9f3792562a97c46125b6230dbc9a4a3489c9c7830077",
        "752d24dc96540f20f1c93df57b32d0b44d30cfe786a1295e05b9b367d3786902",
        "726094e2e45bb32342f1ad4b1934f263cb7e06e49580c580aadd96d01b1e6750",
        "4fa2350178cf8604db4b08ec12cd5d2bec14131df8d66a8f3a89ed8fa8801d3f",
        "176843edb5be864809512a5e7cda83a53015ded9d14a0b8b782c58f400ef3090",
        "07a100f9350c6ac49b0b0e79498a59b6dcc6516cb9c6ae97c97f72b164b5321d",
        "46bc58e60859b0230e7915aa1e0298d3570676370b6f2304050cba665de315bc",
        "bdda50dd59cad77c77600f9a0dd53cf76e08053a2c33fa16edee7285001dea88",
        "1f9c89dc8208d26b5f4776fec7c4c265182a37a947751faacfd756da38ece4b9",
        "9fa1a1500601197c20e8a87871c352bdc4d4baa51aee7ea566fa193e1e3b564f",
        "17e8155817a1b24035476688a8ffe9c36c7fe4b7ba1e4f1e9e023139245c3a3c",
        "db54b22144dc9782865f30fe87edabecaa09d2a3cff95f9aeb0bfdedb61a6eb7",
        "152c538a195c90e4f89aed7b59ebec8b88e01f697e2318437c29495547e03b24",
        "3895b72e4d4621373d386176970b055d18895c8139ec8b15c76b251b596c7d85",
        "6e98349c5593285fc05697567342a4a83c1d5cc08753ff64dbb6bd4c194f5b72",
        "a09ab8fa43d6e2b5261389d51ec65b0fb69de70543ba77c4bde07ab11a101b74",
        "9da6ada86e1f0766677c9a493550b7759d09e621faba81bd2b9e67dde38a5522",
        "4be6ee11b43ef9b53a123f1f62a645e3ed0b74cd7004f9c6578613c5bc9ad2ef",
        "5a0be36e82f7fa3c18df959f48f80660b8f105d66b5554ad6b34241e83ba3055",
        "5f7fa8059fcdbd20353522d1ac667887f8e44c029e11c3bc9c9767260917b911",
        "10ca30005fece8243eadacc6bef68421ef6d9f4fffb2566e4d868580e9ac4c85",
        "d12ec34eca906669fbef7b40109e11cbf0c359774fb5a80bbbd3c1e2b5798ad3",
        "40b7c17c6f0aab217b8921f8f421336c007749ed157cda48bbf4fa8ed038a4ae",
        "f8c59d3fe58a42fa77bdc7932bf531b419b2c4a169119c027bdeb21e7f2ae842",
        "302180d81debe8bc0aafcbd223b065c8754d7ab0acafde42f7a334fd3d28b5a2",
        "9bd3833c52f7a15b305ea7ac9f885e12e976f0d0b12a05f8d6bfb1ad1ac8f904",
        "aac67c4b7ef1f8145012bd21f323e80beb24f0f6e63852429a564da60b5bb887",
        "38e624b95236fb1dd1336085dfccc7bd5c2d71ec5a4d70b8a6290814fdf4ec71",
        "4058d71770d4aae38d4b7113ca7f35f6ef9a019bd6850ad7cc137613b3818936",
        "d70187eb317cf02f1eaca3ea1b53023ce33d9ecf213d0571704b08b82a6f322c",
        "33c67f5c1c81f063333b9f1aec31e4b6f14f1e43adc4e17d11c6e1cca9ef3119",
        "afd9eba1f241ec59fe83a44f295b1bf80f71cf987365dc0ac688228fa6e93f9f",
        "3b2fd5eb5f302c7a0767590e1c99cac2f45aa99961334515def65057dccc3cae",
        "e1ecc64507f5861ceaf8101824df3700a6e1c641d35dc151769a4f3a30037800",
        "0649bacd4e8e19d8f2f552a22ec144b794fe32e300ed77a1b7520b80336886be",
        "4e6ed319b78cb362188f17d89e71c7bc756b23c1c3691ef8e9af9c0cb345eb2e",
        "ddfc3374f2655ab7989c3ac7a088eddf0c0c1e6dcc77ac9188cdeaab417044f9",
        "e9ef531bf362588785c205085a7aa5558774196c68d4f46d7067e84b81c1aa9b",
        "06a4cbeb6a1e4acaf606ba348de8dbd7d8b190125f87562ad7ff6cbf87fcce70",
        "9a08139367da0c1d78ca945de5ce4d30549526534cc8931e8ae1371be8ce4190",
        "9fc4999a212ade7d397d74b6f8c71ec653ed560f7a1992296b3cd2cb543f6653",
        "c9797e1a1f06ff193d31f29f7cb887ac47eb4de02ccb6a09b440c3e4408ec989"
    ]
    static let hundredLongMemoryConfigurationSHA256 = independentLongMemoryConfigurationSHA256
    static let witnessMode = "sufficient-exchange-pack-v1"
    private enum Failure: Error { case arguments, invalid, io }
    /// A command-level amendment keeps the exact v7 source/configuration pins
    /// intact while giving this different answering path a separate identity.
    private enum PreparationMode: String {
        case ordinary = "ordinary-v1"
        case investigation = "native-investigation-paired-v1"
        func validate(_ document: Document) throws {
            guard (self == .ordinary ? document.version != 8 : [7, 8].contains(document.version)) else { throw Failure.invalid }
        }
        func investigates(_ attempt: Attempt) -> Bool {
            self == .investigation && attempt.strategy == .hybrid
        }
        func settings(_ configuration: Configuration, attempt: Attempt) -> GenerationSettings {
            var value = configuration.settings
            value.investigateMemory = investigates(attempt)
            return value
        }
        func constructsSemanticIndex(version: Int, attempt: Attempt) -> Bool {
            attempt.strategy == .hybrid && version != 6 && !investigates(attempt)
        }
    }
    private struct InvocationOptions {
        let input: String, output: String
        let preparationMode: PreparationMode
        /// Context source framing. Unpinned runs use the current default
        /// (V4); `--context-framing context-source-snapshot-v3` reproduces
        /// runs recorded before V4.
        var framing = ContextSourceFraming.defaultSelectionVersion
        var framingPinned = false
        /// Optional single declared attempt (zero-based ordinal). Other
        /// declared attempts are recorded as not selected and never generated.
        var onlyAttempt: Int? = nil
        /// Optional explicit existing component policy, e.g. the experimental
        /// bounded-neighborhood policy that an earlier run froze as default.
        var componentPolicy: ContextComponentPolicy? = nil
        /// Optional retrieval arm for declared `hybrid` attempts:
        /// `--retrieval-arm ordinary_send` runs them in the ordinary Send
        /// configuration (AnswerEvaluationRetrievalArm). Nil keeps every
        /// declared strategy exactly as before.
        var retrievalArm: AnswerEvaluationRetrievalArm? = nil
    }
    static let pinnableFramings = [ContextSourceFraming.currentSelectionVersion, ContextSourceFraming.quotedSelectionVersion]
    private static func invocationOptions(_ args: [String]) throws -> InvocationOptions {
        guard args.count >= 4, args[0] == "--answer-evaluation", args[2] == "--output-directory" else { throw Failure.arguments }
        if args.count == 5 {
            guard args[4] == "--investigate-memory" else { throw Failure.arguments }
            return InvocationOptions(input: args[1], output: args[3], preparationMode: .investigation)
        }
        var options = InvocationOptions(input: args[1], output: args[3], preparationMode: .ordinary)
        var rest = Array(args.dropFirst(4)), seen = Set<String>()
        guard rest.count % 2 == 0 else { throw Failure.arguments }
        while !rest.isEmpty {
            let flag = rest.removeFirst(), value = rest.removeFirst()
            guard seen.insert(flag).inserted else { throw Failure.arguments }
            switch flag {
            case "--context-framing":
                guard pinnableFramings.contains(value) else { throw Failure.arguments }
                options.framing = value; options.framingPinned = true
            case "--attempt":
                guard let ordinal = Int(value), String(ordinal) == value, (0...999).contains(ordinal) else { throw Failure.arguments }
                options.onlyAttempt = ordinal
            case "--component-policy":
                let policies = [ContextComponentPolicy.selectedQwen, .selectedQwenNeighborhood]
                guard let policy = policies.first(where: { $0.version == value }) else { throw Failure.arguments }
                options.componentPolicy = policy
            case "--retrieval-arm":
                guard let arm = AnswerEvaluationRetrievalArm(rawValue: value), AnswerEvaluationRetrievalArm.selectable.contains(arm),
                      arm != .ordinarySend || AnswerEvaluationRetrievalArm.ordinarySendSelectable else { throw Failure.arguments }
                options.retrievalArm = arm
            default: throw Failure.arguments
            }
        }
        return options
    }
    /// A selected retrieval arm must change at least one attempt this
    /// invocation runs, so a report that names the arm is never vacuous. The
    /// declared-source control (version 6) delivers declared IDs instead of
    /// selecting, so it has no ordinary Send counterpart.
    private static func validateRetrievalArm(_ options: InvocationOptions, _ document: Document) throws {
        guard options.retrievalArm != nil else { return }
        guard document.version != 6, document.attempts.indices.contains(where: { index in
            (options.onlyAttempt == nil || options.onlyAttempt == index) && document.attempts[index].strategy == .hybrid
        }) else { throw Failure.arguments }
    }
    private struct Event: Decodable {
        let id: String
        let project_id: String
        let conversation_key: String
        let role: String
        let status: CaptureStatus
        let text: String
        let source_time: EventSourceTime?
    }
    private struct Attempt: Decodable {
        let probe_id: String
        let project_id: String
        let conversation_key: String
        let prompt: String
        let strategy: ContextRetrievalStrategy
        let replicate: Int
        let question_time: EventSourceTime?
        let evidence_source_ids: [String]?
        var effectivePrompt: String {
            guard let time = question_time else { return prompt }
            return "Question Date: " + time.originalValue + "\nQuestion: " + prompt
        }
        var lexicalQueryUTF8Range: Range<Int>? {
            guard question_time != nil else { return nil }
            let end = effectivePrompt.utf8.count
            return (end - prompt.utf8.count)..<end
        }
    }
    private struct Configuration: Decodable {
        let endpoint: String
        let model: String
        let system: String
        let temperature: Double
        let seed: Int
        let thinking: Bool
        let maximum_output: Int
        let context_limit: Int
        let safety_tokens: Int
        let response_format: String?
        var settings: GenerationSettings {
            var value = GenerationSettings()
            value.profile = .customLocal; value.endpointURL = endpoint; value.endpointModel = model
            value.system = system; value.temperature = temperature; value.seed = seed
            value.thinkingEnabled = thinking; value.maximumOutput = maximum_output
            value.endpointContextLimit = context_limit; value.endpointSafetyTokens = safety_tokens
            value.endpointJSONOutput = response_format == "json_object"
            return value
        }
    }
    private struct Document: Decodable {
        let version: Int
        let split: String
        let history_id: String
        let events: [Event]
        let attempts: [Attempt]
        let configuration: Configuration
    }

    /// Like the application smoke driver, a recognized valid command owns the
    /// main dispatch loop until all attempts terminalize. Invalid commands
    /// return a status so the ordinary application entry point can exit.
    static func run(arguments: [String]) -> Int32? {
        var args = arguments
        if let first = args.first, !first.hasPrefix("--") { args.removeFirst() }
        guard args.contains("--answer-evaluation") else { return nil }
        do {
            let options = try invocationOptions(args)
            let input = try checkedPath(options.input), output = try checkedPath(options.output)
            let bytes = try readPrivateInput(input)
            let document = try decode(bytes)
            try options.preparationMode.validate(document)
            if let only = options.onlyAttempt { guard only < document.attempts.count else { throw Failure.arguments } }
            try validateRetrievalArm(options, document)
            try createNewDirectory(output)
            let session = try Session(document: document, inputDigest: digest(bytes),
                projectionDigest: projectionSHA256(bytes), output: output, preparationMode: options.preparationMode,
                options: options)
            DispatchQueue.global(qos: .userInitiated).async { session.begin() }
            dispatchMain()
        } catch Failure.arguments {
            fputs("Usage: --answer-evaluation ABS_JSON --output-directory NEW_ABS [--investigate-memory | [--context-framing VERSION] [--attempt N] [--component-policy VERSION] [--retrieval-arm ordinary_send]].\n", stderr)
            return 2
        } catch {
            fputs("Answer evaluation input or destination failed validation.\n", stderr)
            return 1
        }
    }

    private struct InputPins {
        let ordinary: Set<String>, witness: Set<String>, witnessConfiguration: String
        var formatConfiguration: String? = nil
        var jsonWitness: Set<String> = []
        var jsonConfiguration: String? = nil
        var longMemory: Set<String> = []
        var longMemoryConfiguration: String? = nil
        var semanticLongMemory: Set<String> = []
        var completeSourceLongMemory: Set<String> = []
        var independentLongMemory: Set<String> = []
        var independentLongMemoryConfiguration: String? = nil
        var hundredLongMemory: Set<String> = []
        var hundredLongMemoryConfiguration: String? = nil
        static var production: InputPins {
            InputPins(ordinary: developerCorpusProjectionSHA256.union([publicCorpusProjectionSHA256]),
                witness: witnessCorpusProjectionSHA256, witnessConfiguration: witnessConfigurationSHA256,
                formatConfiguration: formatInstructionConfigurationSHA256,
                jsonWitness: jsonObjectCorpusProjectionSHA256, jsonConfiguration: jsonObjectConfigurationSHA256,
                longMemory: longMemoryCorpusProjectionSHA256, longMemoryConfiguration: longMemoryConfigurationSHA256,
                semanticLongMemory: semanticLongMemoryCorpusProjectionSHA256,
                completeSourceLongMemory: completeSourceLongMemoryCorpusProjectionSHA256,
                independentLongMemory: independentLongMemoryCorpusProjectionSHA256,
                independentLongMemoryConfiguration: independentLongMemoryConfigurationSHA256,
                hundredLongMemory: hundredLongMemoryCorpusProjectionSHA256,
                hundredLongMemoryConfiguration: hundredLongMemoryConfigurationSHA256)
        }
    }
    private static func decode(_ bytes: Data, pins: InputPins = .production) throws -> Document {
        var scanner = UniqueKeyScanner(bytes: Array(bytes)); try scanner.scan()
        guard let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(root.keys) == ["version", "split", "history_id", "events", "attempts", "configuration"],
              let events = root["events"] as? [[String: Any]],
              let attempts = root["attempts"] as? [[String: Any]],
              let configuration = root["configuration"] as? [String: Any] else { throw Failure.invalid }
        var publicProjection = root
        publicProjection.removeValue(forKey: "configuration")
        let projectionDigest = digest(try JSONSerialization.data(withJSONObject: publicProjection,
            options: [.sortedKeys, .withoutEscapingSlashes]))
        guard let mode = root["version"] as? NSNumber, CFGetTypeID(mode) != CFBooleanGetTypeID(),
              mode.doubleValue == Double(mode.intValue), (1...8).contains(mode.intValue) else { throw Failure.invalid }
        let eventKeys: Set<String> = ["id", "project_id", "conversation_key", "role", "status", "text"]
        let attemptKeys: Set<String> = ["probe_id", "project_id", "conversation_key", "prompt", "strategy", "replicate"]
        guard events.allSatisfy({ Set($0.keys) == (mode.intValue >= 4 ? eventKeys.union(["source_time"]) : eventKeys) }),
              attempts.allSatisfy({ Set($0.keys) == (mode.intValue == 6 ? attemptKeys.union(["question_time", "evidence_source_ids"])
                  : mode.intValue >= 4 ? attemptKeys.union(["question_time"]) : attemptKeys) }) else { throw Failure.invalid }
        let baseKeys: Set<String> = ["endpoint", "model", "system", "temperature", "seed", "thinking", "maximum_output", "context_limit", "safety_tokens"]
        guard Set(configuration.keys) == (mode.intValue == 3 ? baseKeys.union(["response_format"]) : baseKeys),
              mode.intValue != 3 || configuration["response_format"] as? String == "json_object" else { throw Failure.invalid }
        if mode.intValue == 1 {
            guard pins.ordinary.contains(projectionDigest) else { throw Failure.invalid }
        } else if mode.intValue == 2 {
            let configurationDigest = digest(try JSONSerialization.data(withJSONObject: configuration,
                options: [.sortedKeys, .withoutEscapingSlashes]))
            guard pins.witness.contains(projectionDigest),
                  configurationDigest == pins.witnessConfiguration
                    || configurationDigest == pins.formatConfiguration else { throw Failure.invalid }
        } else if mode.intValue == 3 {
            guard pins.jsonWitness.contains(projectionDigest),
                  digest(try JSONSerialization.data(withJSONObject: configuration,
                    options: [.sortedKeys, .withoutEscapingSlashes])) == pins.jsonConfiguration else { throw Failure.invalid }
        } else if mode.intValue == 8 {
            guard pins.hundredLongMemory.contains(projectionDigest),
                  digest(try JSONSerialization.data(withJSONObject: configuration,
                    options: [.sortedKeys, .withoutEscapingSlashes])) == pins.hundredLongMemoryConfiguration else { throw Failure.invalid }
        } else if mode.intValue == 7 {
            guard pins.independentLongMemory.contains(projectionDigest),
                  digest(try JSONSerialization.data(withJSONObject: configuration,
                    options: [.sortedKeys, .withoutEscapingSlashes])) == pins.independentLongMemoryConfiguration else { throw Failure.invalid }
        } else {
            let projections = mode.intValue == 4 ? pins.longMemory
                : mode.intValue == 5 ? pins.semanticLongMemory : pins.completeSourceLongMemory
            guard projections.contains(projectionDigest),
                  digest(try JSONSerialization.data(withJSONObject: configuration,
                    options: [.sortedKeys, .withoutEscapingSlashes])) == pins.longMemoryConfiguration else { throw Failure.invalid }
        }
        let value = try JSONDecoder().decode(Document.self, from: bytes)
        guard value.split == "development", identifier(value.history_id),
              !value.events.isEmpty, value.events.count <= 100_000,
              !value.attempts.isEmpty, value.attempts.count <= 1000,
              Set(value.events.map(\.id)).count == value.events.count else { throw Failure.invalid }
        var conversations = Set<String>(), attemptsSeen = Set<String>()
        for event in value.events {
            guard identifier(event.id), identifier(event.project_id), identifier(event.conversation_key),
                  ["user", "assistant"].contains(event.role), event.text.utf8.count <= MemoryStore.maximumPayloadBytes else { throw Failure.invalid }
            if value.version >= 4 {
                guard let sourceTime = event.source_time else { throw Failure.invalid }
                _ = try sourceTime.validated()
            }
            conversations.insert(key(event.project_id, event.conversation_key))
        }
        for attempt in value.attempts {
            guard identifier(attempt.probe_id), identifier(attempt.project_id), identifier(attempt.conversation_key),
                  conversations.contains(key(attempt.project_id, attempt.conversation_key)),
                  !attempt.prompt.isEmpty, attempt.effectivePrompt.utf8.count <= MemoryStore.maximumPayloadBytes,
                  (0...100).contains(attempt.replicate),
                  attemptsSeen.insert("\(attempt.probe_id)|\(attempt.strategy.rawValue)|\(attempt.replicate)").inserted else { throw Failure.invalid }
        }
        if value.version >= 4 {
            guard value.attempts.count == ([6, 8].contains(value.version) ? 1 : 2),
                  value.attempts.map(\.strategy) == ([6, 8].contains(value.version) ? [.hybrid] : [.recentOnly, .hybrid]),
                  value.attempts.allSatisfy({ $0.replicate == 0 && $0.question_time != nil }),
                  value.events.allSatisfy({ $0.status == .complete }),
                  Set(value.events.map(\.project_id)).count == 1 else { throw Failure.invalid }
            for attempt in value.attempts { _ = try attempt.question_time!.validated() }
        }
        if value.version == 6 {
            guard let attempt = value.attempts.first, let ids = attempt.evidence_source_ids,
                  !ids.isEmpty, ids.count <= 16, ExactSourceIDs(ids).count == ids.count,
                  ids.allSatisfy({ id in
                      identifier(id) && value.events.contains { event in
                          episodeIdentifierEqual(event.id, id) && episodeIdentifierEqual(event.project_id, attempt.project_id)
                              && event.status == .complete && !event.text.isEmpty
                              && event.text.utf8.count <= MemoryStore.maximumPageBytes
                      }
                  }) else { throw Failure.invalid }
        }
        if (2...3).contains(value.version) {
            guard value.attempts.count == 1, let attempt = value.attempts.first,
                  attempt.strategy == .recentOnly, attempt.replicate == 0,
                  value.events.count == 2 || value.events.count == 4,
                  value.events.enumerated().allSatisfy({ index, event in
                      episodeIdentifierEqual(event.project_id, attempt.project_id)
                        && episodeIdentifierEqual(event.conversation_key, attempt.conversation_key)
                        && event.role == (index % 2 == 0 ? "user" : "assistant")
                        && event.status == .complete && !event.text.isEmpty
                  }) else { throw Failure.invalid }
        }
        let c = value.configuration
        guard LocalEndpoint.chatURL(c.endpoint) != nil, c.model == Qwen38TextRendering.modelID,
              !c.system.isEmpty, c.system.utf8.count <= 8192, c.temperature.isFinite, (0...2).contains(c.temperature),
              (0...Int(Int32.max)).contains(c.seed), (1...8192).contains(c.maximum_output),
              (1024...131072).contains(c.context_limit), (0...8192).contains(c.safety_tokens),
              c.maximum_output + c.safety_tokens < c.context_limit else { throw Failure.invalid }
        _ = try EndpointRequest.build(prompt: value.attempts[0].effectivePrompt, settings: c.settings, conversation: Conversation())
        return value
    }

    private static func projectionSHA256(_ bytes: Data) throws -> String {
        guard var projection = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw Failure.invalid }
        projection.removeValue(forKey: "configuration")
        return digest(try JSONSerialization.data(withJSONObject: projection, options: [.sortedKeys, .withoutEscapingSlashes]))
    }

    private static func ingestEvents(_ document: Document, into owner: MemoryStore) throws -> [String: String] {
        var conversations: [String: String] = [:]
        for event in document.events {
            let mapping = key(event.project_id, event.conversation_key)
            if conversations[mapping] == nil {
                conversations[mapping] = try owner.createConversation(projectID: project(event.project_id), title: "Public diagnostic corpus").id
            }
            _ = try owner.append(conversationID: conversations[mapping]!, role: event.role == "user" ? .human : .assistant,
                text: event.text, status: event.status, turnID: "public-turn:" + event.id, eventID: event.id, sourceTime: event.source_time)
        }
        return conversations
    }

    private final class Session {
        let document: Document
        let inputDigest: String
        let projectionDigest: String
        let output: URL
        let runtime: URL
        let archive: URL
        let preparationMode: PreparationMode
        let options: InvocationOptions?
        var framing: String { options?.framing ?? ContextSourceFraming.defaultSelectionVersion }
        var conversations: [String: String] = [:]
        var report: [[String: Any]] = []
        var baseline: [String: Any] = [:]
        var ordinal = 0
        var coordinator: AnswerAttemptCoordinator?
        var stoppedAfterOperationalFailure = false
        init(document: Document, inputDigest: String, projectionDigest: String, output: URL,
             preparationMode: PreparationMode = .ordinary, options: InvocationOptions? = nil) throws {
            try preparationMode.validate(document)
            self.document = document; self.inputDigest = inputDigest; self.projectionDigest = projectionDigest; self.output = output
            self.preparationMode = preparationMode; self.options = options
            // Keep every store inside the checked private output owner. The
            // Python supervisor can remove this subtree even if this process
            // dies before native finalization. Direct CLI owners retain it on
            // death until they remove their explicitly chosen output directory.
            runtime = output.appendingPathComponent(".runtime-" + UUID().uuidString, isDirectory: true)
            archive = runtime.appendingPathComponent("checkpoint", isDirectory: true)
            try createNewDirectory(runtime)
        }
        func begin() {
            do {
                try ingestCheckpoint()
                advance()
            } catch { finish(fatal: "checkpoint_failed") }
        }
        private func ingestCheckpoint() throws {
            let owner = try MemoryStore(directory: runtime.appendingPathComponent("baseline", isDirectory: true))
            conversations = try ingestEvents(document, into: owner)
            let manifest = try BackupArchive.create(from: owner, at: archive)
            baseline = ["events": manifest.inventory.events, "source_bytes": manifest.inventory.sourceBytes,
                "conversations": manifest.inventory.conversations, "archive_id": manifest.archiveID,
                "database_schema": manifest.databaseSchema,
                "archive_sha256": digest(try canonical(manifest)),
                "timestamps": document.version >= 4 ? "original_session_dates_preserved_ingestion_frozen" : "ingestion_frozen_in_checkpoint", "derived_sidecar_in_checkpoint": false]
        }
        private func advance() {
            if stoppedAfterOperationalFailure { finish(fatal: "trial_stopped_after_operational_failure"); return }
            guard ordinal < document.attempts.count else { finish(fatal: nil); return }
            if let only = options?.onlyAttempt, ordinal != only { ordinal += 1; advance(); return }
            let index = ordinal, attempt = document.attempts[index]
            let started = continuousSample()
            let restored = runtime.appendingPathComponent(String(format: "attempt-%04d", index), isDirectory: true)
            do {
                _ = try BackupArchive.restore(from: archive, to: restored, authority: .unmanagedNoDeletion)
                let owner = try MemoryStore(directory: restored)
                let arm = retrievalArm(attempt)
                var semantic: SemanticIndex?
                var construction: [String: Any] = ["schedule": "per_hybrid_attempt_before_acceptance", "performed": false]
                let before = try owner.backgroundBudgetSnapshot()
                let constructionStart = continuousSample()
                if preparationMode.constructsSemanticIndex(version: document.version, attempt: attempt) && arm.buildsSemanticIndex {
                    do {
                        let index = try SemanticIndex(store: owner)
                        semantic = index
                        var slices = 0, published = 0, failed = 0, scheduled = 0, lastFrontier = 0
                        // No renewal, fresh clock or store is manufactured here.
                        // A stopped/paused slice ends construction for this attempt.
                        while true {
                            let receipt = try index.process(projectID: project(attempt.project_id))
                            slices += 1; published += receipt.publishedChunks; failed += receipt.failedChunks
                            scheduled += receipt.scheduledSources; lastFrontier = receipt.schedulingFrontier
                            if receipt.budgetPauseReason != nil || (receipt.scheduledSources == 0 && receipt.publishedChunks == 0 && receipt.failedChunks == 0) { break }
                        }
                        construction = ["schedule": "per_hybrid_attempt_before_acceptance", "performed": true,
                            "slices": slices, "published_chunks": published, "failed_chunks": failed,
                            "scheduled_sources": scheduled, "frontier": lastFrontier,
                            "pause_reason": index.backgroundPauseReason as Any? ?? NSNull(),
                            "index_fingerprint": index.indexFingerprint, "encoder_fingerprint": index.encoderFingerprint,
                            "ranking_fingerprint": index.rankingFingerprint,
                            "configuration": try object(index.configuration),
                            "inventory": try sidecarInventory(index.directory)]
                    } catch {
                        construction = ["schedule": "per_hybrid_attempt_before_acceptance", "performed": true,
                            "failure": "index_construction_failed", "partial_coverage": true]
                    }
                }
                if arm == .ordinarySend {
                    // The GUI host's own entry point: under the ordinary Send
                    // policy it opens no sidecar and runs no encoder probe.
                    semantic = try arm.hostIndex(store: owner)
                    construction = ["schedule": "skipped_ordinary_send_semantic_disabled_by_policy", "performed": false,
                        "host_index_opened": semantic != nil]
                }
                construction["milliseconds"] = milliseconds(constructionStart)
                construction["budget_before"] = try object(before)
                construction["budget_after"] = try object(owner.backgroundBudgetSnapshot())
                construction["quiescent_during_answer"] = true
                if document.version == 6 { construction["schedule"] = "skipped_declared_original_sources_control" }
                if preparationMode.investigates(attempt) { construction["schedule"] = "skipped_native_investigation_lexical_navigation" }
                let frozenConstruction = construction, frozenSemantic = semantic
                DispatchQueue.main.async {
                    self.answer(attempt, ordinal: index, owner: owner, semantic: frozenSemantic,
                        construction: frozenConstruction, restored: restored, started: started)
                }
            } catch {
                do {
                    var item = metadata(attempt, ordinal: index)
                    item["terminalized"] = true; item["failure_stage"] = "restore_or_setup"
                    item["failure"] = "attempt_setup_failed"; item["answer_bytes"] = 0
                    item["answer_sha256"] = digest(Data()); item["episode_state"] = NSNull()
                    item["invocation_status"] = NSNull(); item["delivered_ranges"] = []
                    item["delivered_recent_source_ids"] = []; item["full_host_milliseconds"] = milliseconds(started)
                    try publish(item, text: "", ordinal: index)
                    stoppedAfterOperationalFailure = preparationMode == .investigation
                    if preparationMode == .ordinary { try? FileManager.default.removeItem(at: restored) }
                    ordinal += 1; advance()
                } catch { finish(fatal: "ipc_publication_failed") }
            }
        }
        private func answer(_ attempt: Attempt, ordinal: Int, owner: MemoryStore, semantic: SemanticIndex?,
                            construction: [String: Any], restored: URL, started: UInt64?) {
            var settings = preparationMode.settings(document.configuration, attempt: attempt)
            settings.contextFraming = framing
            var limits: EpisodeLimits?
            if let policy = options?.componentPolicy { var value = EpisodeLimits(); value.componentPolicy = policy; limits = value }
            let arm = retrievalArm(attempt)
            let value = AnswerEvaluationCommand.coordinator(document: document, attempt: attempt, arm: arm, owner: owner,
                conversationID: conversations[key(attempt.project_id, attempt.conversation_key)]!,
                settings: settings, limits: limits, semantic: semantic,
                onComplete: { completion, text in
                    do {
                        var item = self.metadata(attempt, ordinal: ordinal)
                        item["terminalized"] = true; item["background"] = construction
                        if self.options?.retrievalArm != nil {
                            item["preparation_received_semantic_index"] = self.coordinator?.preparationReceivesSemanticIndex as Any? ?? NSNull()
                            item["semantic_sidecar_present"] = FileManager.default.fileExists(
                                atPath: owner.directory.appendingPathComponent("semantic", isDirectory: true).path)
                        }
                        item["identifiers"] = try object(completion.identifiers)
                        item["episode"] = try completion.episode.map { try object($0) } ?? NSNull()
                        item["episode_state"] = completion.episode?.state.rawValue as Any? ?? NSNull()
                        item["invocation_status"] = completion.captureStatus?.rawValue as Any? ?? NSNull()
                        item["terminal_reason"] = completion.terminalReason?.rawValue as Any? ?? NSNull()
                        item["capture_healthy"] = completion.captureHealthy; item["accounting_healthy"] = completion.accountingHealthy
                        if self.document.version == 8 {
                            for (field, count) in try terminalWorkInventory(restored, episodeID: completion.identifiers.episodeID) {
                                item[field] = count
                            }
                        }
                        item["invocation_started"] = completion.invocationStarted
                        item["failure"] = completion.generation.failure as Any? ?? NSNull()
                        item["failure_stage"] = completion.preparation == nil ? "preparation" : completion.generation.failure == nil ? "none" : "answer_or_finalization"
                        item["provider_usage"] = try completion.generation.providerUsage.map { try object($0) } ?? NSNull()
                        item["provider_milliseconds"] = completion.generation.elapsed * 1000
                        item["timing"] = try object(completion.timing)
                        item["answer_bytes"] = completion.responseBytes; item["answer_sha256"] = completion.responseDigest
                        let inventory = try sourceInventory(restored)
                        item["overlay_events"] = inventory.events - self.document.events.count
                        item["overlay_bytes"] = inventory.bytes - self.document.events.reduce(0) { $0 + $1.text.utf8.count }
                        item["delivered_ranges"] = []; item["delivered_recent_source_ids"] = []
                        if let preparation = completion.preparation {
                            guard let audit = try JSONSerialization.jsonObject(with: preparation.contextAudit) as? [String: Any] else { throw Failure.invalid }
                            if self.preparationMode == .investigation {
                                let native = (audit["retrieval"] as? [String: Any])?["native_investigation"] as? [String: Any]
                                guard self.preparationMode.investigates(attempt)
                                    ? native?["version"] as? String == "native-investigation-v1"
                                    : native == nil else { throw Failure.invalid }
                                item["preparation_mode_receipt_validated"] = true
                            }
                            if arm == .ordinarySend {
                                // The receipt must show the policy withheld the index.
                                let retrieval = audit["retrieval"] as? [String: Any]
                                guard retrieval?[SemanticRetrievalPolicy.auditField] as? String == SemanticRetrievalPolicy.disabledByPolicy.rawValue,
                                      retrieval?["mode"] as? String == "lexical", retrieval?["manifest_id"] == nil else { throw Failure.invalid }
                                item["retrieval_arm_receipt_validated"] = true
                            }
                            item["preparation"] = ["request_sha256": preparation.requestDigest,
                                "selection_sha256": preparation.sourceSelectionDigest,
                                "selection_work_id": preparation.sourceSelectionWorkID as Any? ?? NSNull(),
                                "answer_work_id": preparation.answerWorkID,
                                "admission": try object(preparation.admission), "context_audit": audit]
                            if self.document.version >= 4 {
                                var metadata = item["preparation"] as! [String: Any]
                                metadata["admission_audit"] = try JSONSerialization.jsonObject(with: preparation.admissionAuditJSON)
                                item["preparation"] = metadata
                            }
                            var ranges = try (audit["historical_sources"] as? [[String: Any]] ?? []).map { source -> [String: Any] in
                                guard let id = source["event_id"], let offset = source["excerpt_offset"],
                                      let length = source["excerpt_bytes"], let hash = source["excerpt_sha256"] else { throw Failure.invalid }
                                return ["event_id": id, "offset": offset, "byte_length": length, "sha256": hash]
                            }
                            if let workID = preparation.sourceSelectionWorkID,
                               let snapshot = try owner.episodeWork(episodeID: completion.identifiers.episodeID, operationID: workID)?.request.snapshot,
                               let selection = try JSONSerialization.jsonObject(with: snapshot) as? [String: Any] {
                                item["delivered_recent_source_ids"] = selection["recent_source_ids"] ?? []
                                item["context_framing"] = selection["version"] ?? NSNull()
                                if let labels = selection["citation_labels"] { item["citation_labels"] = labels }
                                for source in selection["recent_sources"] as? [[String: Any]] ?? [] {
                                    guard let id = source["eventID"], let length = source["byteCount"], let hash = source["digest"] else { throw Failure.invalid }
                                    ranges.append(["event_id": id, "offset": 0, "byte_length": length, "sha256": hash])
                                }
                            }
                            item["delivered_ranges"] = ranges
                        }
                        if (2...3).contains(self.document.version) {
                            item["witness_validation"] = validateWitness(document: self.document, completion: completion,
                                directory: restored, conversationID: self.conversations[key(attempt.project_id, attempt.conversation_key)]!,
                                framing: self.framing)
                        }
                        if self.document.version == 6 {
                            item["source_control_validation"] = validateSourceControl(document: self.document, completion: completion,
                                directory: restored, conversations: self.conversations, framing: self.framing)
                        }
                        item["background_budget_at_completion"] = try object(owner.backgroundBudgetSnapshot())
                        item["full_host_milliseconds"] = milliseconds(started)
                        try self.publish(item, text: text, ordinal: ordinal)
                        self.stoppedAfterOperationalFailure = self.preparationMode == .investigation
                            && !operationallyComplete(completion)
                        self.coordinator = nil
                        // Move teardown off the callback stack, releasing both
                        // owners before removing their disposable directory.
                        DispatchQueue.main.async {
                            DispatchQueue.global(qos: .userInitiated).async {
                                if self.preparationMode == .ordinary { try? FileManager.default.removeItem(at: restored) }
                                self.ordinal += 1; self.advance()
                            }
                        }
                    } catch { self.finish(fatal: "attempt_metadata_failed") }
                })
            coordinator = value
            do { try value.accept(); try value.start() }
            catch {
                // A failed acceptance has no durable episode. Still retain the
                // declared attempt; start failures terminalize an accepted one.
                if (try? value.lease.checkActive(projectID: project(attempt.project_id))) != nil {
                    value.terminate(reason: .failed); return
                }
                do {
                    var item = metadata(attempt, ordinal: ordinal)
                    item["terminalized"] = true; item["background"] = construction
                    item["failure_stage"] = "acceptance"; item["failure"] = "acceptance_failed"
                    item["episode_state"] = NSNull(); item["invocation_status"] = NSNull()
                    item["answer_bytes"] = 0; item["answer_sha256"] = digest(Data())
                    item["delivered_ranges"] = []; item["delivered_recent_source_ids"] = []
                    item["full_host_milliseconds"] = milliseconds(started)
                    try publish(item, text: "", ordinal: ordinal)
                    stoppedAfterOperationalFailure = preparationMode == .investigation
                    coordinator = nil
                    DispatchQueue.main.async {
                        DispatchQueue.global(qos: .userInitiated).async {
                            if self.preparationMode == .ordinary { try? FileManager.default.removeItem(at: restored) }
                            self.ordinal += 1; self.advance()
                        }
                    }
                } catch { finish(fatal: "ipc_publication_failed") }
            }
        }
        /// The declared strategy, unless `--retrieval-arm` selected an arm
        /// for declared hybrid attempts.
        private func retrievalArm(_ attempt: Attempt) -> AnswerEvaluationRetrievalArm {
            AnswerEvaluationRetrievalArm.resolve(declared: attempt.strategy, selected: options?.retrievalArm)
        }
        /// Attempt metadata. Runs with `--retrieval-arm` also record each
        /// attempt's arm and policy; other runs keep the original key set.
        private func metadata(_ attempt: Attempt, ordinal: Int) -> [String: Any] {
            var value = attemptMetadata(attempt, ordinal: ordinal, preparationMode: preparationMode)
            if options?.retrievalArm != nil {
                let arm = retrievalArm(attempt)
                value["retrieval_arm"] = arm.rawValue
                value["semantic_retrieval_policy"] = arm.semanticRetrieval.rawValue
            }
            return value
        }
        private func publish(_ item: [String: Any], text: String, ordinal: Int) throws {
            try writePrivate(Data(text.utf8), output.appendingPathComponent(String(format: "answer-%04d.txt", ordinal)))
            report.append(witnessMetadata(item))
        }
        private func witnessMetadata(_ item: [String: Any]) -> [String: Any] {
            if document.version == 6 {
                var result = item
                if result["source_control_validation"] == nil {
                    result["source_control_validation"] = sourceControlOutcome(document: document, failure: "source_control_outcome_unavailable")
                }
                return result
            }
            guard (2...3).contains(document.version) else { return item }
            var result = item
            result["witness_mode"] = witnessMode
            if result["witness_validation"] == nil {
                result["witness_validation"] = witnessOutcome(events: document.events, failure: "witness_outcome_unavailable")
            }
            return result
        }
        private func finish(fatal: String?) {
            do {
                // Setup/publication failures never shrink the announced
                // denominator. Missing operational outcomes stay explicit;
                // these records cannot be mistaken for completed answers.
                let retained = Set(report.compactMap { $0["ordinal"] as? Int })
                for index in document.attempts.indices where !retained.contains(index) {
                    var item = metadata(document.attempts[index], ordinal: index)
                    let unselected = options?.onlyAttempt.map { $0 != index } ?? false
                    item["terminalized"] = false; item["failure_stage"] = unselected ? "not_selected" : "runner"
                    item["failure"] = unselected ? "attempt_not_selected_by_invocation" : fatal ?? "runner_outcome_unavailable"
                    item["episode_state"] = NSNull(); item["invocation_status"] = NSNull()
                    item["answer_bytes"] = NSNull(); item["answer_sha256"] = NSNull()
                    item["delivered_ranges"] = []; item["delivered_recent_source_ids"] = []
                    report.append(witnessMetadata(item))
                }
                report.sort { ($0["ordinal"] as? Int ?? 0) < ($1["ordinal"] as? Int ?? 0) }
                guard var configuration = try object(EpisodeLimits()) as? [String: Any] else { throw Failure.invalid }
                configuration["componentPolicy"] = try object(options?.componentPolicy ?? ContextComponentPolicy.currentSelectedQwen)
                let c = document.configuration
                var value: [String: Any] = ["version": 1, "diagnostic": "production-answer-development-v1",
                    "split": "development", "history_id": document.history_id, "input_sha256": inputDigest,
                    "public_projection_sha256": projectionDigest,
                    "fatal_failure": fatal as Any? ?? NSNull(), "declared_attempts": document.attempts.count,
                    "completed_attempts": report.filter { $0["terminalized"] as? Bool == true }.count, "baseline": baseline, "attempts": report,
                    "configuration": ["endpoint": c.endpoint, "model": c.model,
                        "instruction_sha256": digest(Data(c.system.utf8)), "temperature": c.temperature,
                        "seed": c.seed, "thinking": c.thinking, "maximum_output": c.maximum_output,
                        "context_limit": c.context_limit, "safety_tokens": c.safety_tokens,
                        "episode_limits": configuration, "background_limits": try object(BackgroundIndexLimits.development)],
                    "unknowns": ["apple_input_tokens", "local_billed_cost", "first_useful_answer"],
                    "context_framing": framing]
                if let options {
                    value["context_framing_pinned"] = options.framingPinned
                    if let only = options.onlyAttempt { value["selected_attempt"] = only }
                    if let policy = options.componentPolicy { value["component_policy_override"] = policy.version }
                    if let arm = options.retrievalArm {
                        value["retrieval_arm_override"] = arm.rawValue
                        value["semantic_retrieval_policy"] = arm.semanticRetrieval.rawValue
                        value["retrieval_arm_applies_to"] = "declared_hybrid_attempts"
                    }
                }
                if document.version >= 2 {
                    if (2...3).contains(document.version) { value["witness_mode"] = witnessMode }
                    var frozenConfiguration: [String: Any] = ["endpoint": c.endpoint, "model": c.model,
                        "system": c.system, "temperature": c.temperature, "seed": c.seed, "thinking": c.thinking,
                        "maximum_output": c.maximum_output, "context_limit": c.context_limit, "safety_tokens": c.safety_tokens]
                    if let format = c.response_format { frozenConfiguration["response_format"] = format }
                    value["native_configuration_sha256"] = digest(try JSONSerialization.data(withJSONObject: frozenConfiguration,
                        options: [.sortedKeys, .withoutEscapingSlashes]))
                }
                if preparationMode == .investigation {
                    value["diagnostic"] = document.version == 8 ? "native-investigation-100-development-v1" : "native-investigation-paired-development-v1"
                    value["mode"] = document.version == 8 ? "native-memory-investigation-100-v1" : "native-memory-investigation-trial-v1"
                    value["preparation_mode"] = document.version == 8 ? "native-investigation-100-v1" : preparationMode.rawValue
                    value["private_runtime_retained"] = true
                    value["private_runtime_directory"] = runtime.lastPathComponent
                    value["stops_after_operational_failure"] = true
                    var trialConfiguration = value["configuration"] as! [String: Any]
                    trialConfiguration["episode_limits"] = ["recent_only": configuration,
                        "hybrid": try object(NativeInvestigationConfiguration.limits)]
                    trialConfiguration["episode_limits_mode"] = "per_strategy"
                    trialConfiguration["maximum_investigation_actions"] = NativeInvestigationConfiguration.maximumActions
                    value["configuration"] = trialConfiguration
                }
                try writePrivate(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), output.appendingPathComponent("report.json"))
                if preparationMode == .ordinary { try FileManager.default.removeItem(at: runtime) }
                FileHandle.standardOutput.write(Data("{\"status\":\"terminalized\",\"attempts\":\(report.count)}\n".utf8))
                Darwin.exit(fatal == nil ? 0 : 1)
            } catch {
                if preparationMode == .ordinary { try? FileManager.default.removeItem(at: runtime) }
                fputs("Answer evaluation report publication failed.\n", stderr); Darwin.exit(1)
            }
        }
    }

    private static func witnessOutcome(events: [Event], delivered: Int? = nil, complete: Bool? = nil,
        revalidated: Bool? = nil, proofVersion: Int? = nil, failure: String?, validationMilliseconds: Any = NSNull()) -> [String: Any] {
        ["version": "sufficient-exchange-pack-validation-v1", "declared_source_count": events.count,
         "declared_source_bytes": events.reduce(0) { $0 + $1.text.utf8.count },
         "delivered_source_count": delivered as Any? ?? NSNull(), "complete_pack_delivered": complete as Any? ?? NSNull(),
         "source_body_count_revalidated": revalidated as Any? ?? NSNull(), "input_proof_version": proofVersion as Any? ?? NSNull(),
         "failure_code": failure as Any? ?? NSNull(), "validation_milliseconds": validationMilliseconds]
    }

    private static func sourceControlOutcome(document: Document, delivered: Int? = nil, complete: Bool? = nil,
        revalidated: Bool? = nil, proofVersion: Int? = nil, failure: String?, validationMilliseconds: Any = NSNull()) -> [String: Any] {
        let ids = ExactSourceIDs(document.attempts.first?.evidence_source_ids ?? [])
        let sources = document.events.filter { ids.contains($0.id) }
        return ["version": "declared-original-sources-v1", "declared_source_count": sources.count,
            "declared_source_bytes": sources.reduce(0) { $0 + $1.text.utf8.count },
            "delivered_source_count": delivered as Any? ?? NSNull(),
            "complete_declared_sources_delivered": complete as Any? ?? NSNull(),
            "source_body_count_revalidated": revalidated as Any? ?? NSNull(),
            "input_proof_version": proofVersion as Any? ?? NSNull(), "failure_code": failure as Any? ?? NSNull(),
            "validation_milliseconds": validationMilliseconds]
    }

    /// Verify counted source delivery independently of answer success. This
    /// offline integrity check never creates answering work or oracle content.
    private static func validateSourceControl(document: Document, completion: AnswerAttemptCompletion,
        directory: URL, conversations: [String: String],
        framing: String = ContextSourceFraming.defaultSelectionVersion) -> [String: Any] {
        guard completion.invocationStarted else {
            return sourceControlOutcome(document: document, failure: "source_control_outcome_unavailable")
        }
        let started = continuousSample()
        do {
            guard document.version == 6, let attempt = document.attempts.first,
                  let ids = attempt.evidence_source_ids, let preparation = completion.preparation,
                  let selectionID = preparation.sourceSelectionWorkID,
                  let conversationID = conversations[key(attempt.project_id, attempt.conversation_key)] else { throw Failure.invalid }
            let declared = ExactSourceIDs(ids)
            let delivered = try withReadOnlySnapshot(directory: directory) { database in
                let rows = try AuthorityStateKernel.rows(database,
                    "SELECT request_body,request_digest,admission_json,episode_id,project_id,conversation_id,human_event_id,episode_work_id FROM invocations WHERE id=?",
                    [.text(completion.identifiers.invocationID)])
                guard rows.count == 1, let body = rows[0][0].bytes, let admission = rows[0][2].bytes,
                      digest(body) == preparation.requestDigest, episodeIdentifierEqual(rows[0][1].string, preparation.requestDigest),
                      admission == preparation.admissionAuditJSON,
                      episodeIdentifierEqual(rows[0][3].string, completion.identifiers.episodeID),
                      episodeIdentifierEqual(rows[0][4].string, project(attempt.project_id)),
                      episodeIdentifierEqual(rows[0][5].string, conversationID),
                      episodeIdentifierEqual(rows[0][6].string, completion.identifiers.humanEventID),
                      episodeIdentifierEqual(rows[0][7].string, preparation.answerWorkID),
                      let audit = try JSONSerialization.jsonObject(with: admission) as? [String: Any], audit["version"] as? Int == 3,
                      let contextText = audit["context"] as? String, let context = Data(base64Encoded: contextText),
                      context == preparation.contextAudit,
                      let storedReceipt = audit["receipt"],
                      let contextObject = try JSONSerialization.jsonObject(with: context) as? [String: Any],
                      episodeIdentifierEqual(contextObject["selection_work_id"] as? String, selectionID),
                      episodeIdentifierEqual(contextObject["source_snapshot_sha256"] as? String, preparation.sourceSelectionDigest),
                      let bodyObject = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let messages = bodyObject["messages"] as? [[String: String]], messages.count >= 2 else { throw Failure.invalid }
                let mandatory = ContextAssembler.mandatoryMessages(prompt: attempt.effectivePrompt, system: document.configuration.system,
                    selectionVersion: framing)
                let declaredBytes = document.events.filter { declared.contains($0.id) }.reduce(0) { $0 + $1.text.utf8.count }
                guard let retrieval = contextObject["retrieval"] as? [String: Any],
                      retrieval["mode"] as? String == "declared_original_sources",
                      retrieval["version"] as? String == "declared-original-sources-v1",
                      retrieval["declared_source_count"] as? Int == ids.count,
                      retrieval["declared_source_bytes"] as? Int == declaredBytes,
                      retrieval["declared_source_ids_sha256"] as? String == digest(try JSONEncoder().encode(ids)),
                      retrieval["semantic_available"] as? Bool == false else { throw Failure.invalid }
                guard messages.first?["role"] == mandatory[0].role, messages.last?["role"] == mandatory[1].role,
                      Data((messages.first?["content"] ?? "").utf8) == Data(mandatory[0].content.utf8),
                      Data((messages.last?["content"] ?? "").utf8) == Data(mandatory[1].content.utf8) else { throw Failure.invalid }
                var expectedSettings = document.configuration.settings
                expectedSettings.messagesOverride = messages
                guard try EndpointRequest.build(prompt: attempt.effectivePrompt, settings: expectedSettings, conversation: Conversation()) == body,
                      try JSONSerialization.data(withJSONObject: storedReceipt, options: [.sortedKeys, .withoutEscapingSlashes])
                        == JSONSerialization.data(withJSONObject: object(preparation.admission), options: [.sortedKeys, .withoutEscapingSlashes]) else { throw Failure.invalid }
                try ContextComponentJournal.validate(database: database, invocationID: completion.identifiers.invocationID, verifySourceRanges: true)
                let selectionRows = try AuthorityStateKernel.rows(database,
                    "SELECT w.state,w.kind,s.payload FROM episode_work w JOIN episode_request_snapshots s ON s.digest=w.snapshot_digest WHERE w.id=? AND w.episode_id=?",
                    [.text(selectionID), .text(completion.identifiers.episodeID)])
                guard selectionRows.count == 1, selectionRows[0][0].string == "completed", selectionRows[0][1].string == "sourceRead",
                      let selection = selectionRows[0][2].bytes, digest(selection) == preparation.sourceSelectionDigest,
                      let selected = try JSONSerialization.jsonObject(with: selection) as? [String: Any],
                      let recent = selected["recent_sources"] as? [[String: Any]],
                      let historical = selected["historical_sources"] as? [[String: Any]],
                      let recentIDs = selected["recent_source_ids"] as? [String], recentIDs.count == recent.count,
                      ExactSourceIDs(recentIDs).count == recentIDs.count else { throw Failure.invalid }
                // All original history remains intact and ordered across its
                // original conversations; no exchange alternation is assumed.
                var previousSequence = 0
                for event in document.events {
                    let original = try AuthorityStateKernel.rows(database,
                        "SELECT sequence,project_id,conversation_id,role,status,digest,byte_count,payload,source_time_json FROM events WHERE id=?",
                        [.text(event.id)])
                    let bytes = Data(event.text.utf8)
                    guard original.count == 1, original[0][0].integer > previousSequence,
                          episodeIdentifierEqual(original[0][1].string, project(event.project_id)),
                          episodeIdentifierEqual(original[0][2].string, conversations[key(event.project_id, event.conversation_key)]),
                          original[0][3].string == (event.role == "user" ? "human" : "assistant"),
                          original[0][4].string == event.status.rawValue, original[0][5].string == digest(bytes),
                          original[0][6].integer == bytes.count, original[0][7].bytes == bytes,
                          original[0][8].bytes == (try event.source_time?.canonicalData()) else { throw Failure.invalid }
                    previousSequence = original[0][0].integer
                }
                var deliveredIDs = Set<Data>()
                for (index, source) in recent.enumerated() {
                    guard let id = source["eventID"] as? String, episodeIdentifierEqual(id, recentIDs[index]),
                          let event = document.events.first(where: { episodeIdentifierEqual($0.id, id) }),
                          source["digest"] as? String == digest(Data(event.text.utf8)),
                          source["byteCount"] as? Int == event.text.utf8.count else { throw Failure.invalid }
                    if declared.contains(id) { deliveredIDs.insert(Data(id.utf8)) }
                }
                for source in historical {
                    guard let id = source["event_id"] as? String, declared.contains(id), !deliveredIDs.contains(Data(id.utf8)),
                          let event = document.events.first(where: { episodeIdentifierEqual($0.id, id) }),
                          source["excerpt_offset"] as? Int == 0, source["excerpt_bytes"] as? Int == event.text.utf8.count,
                          source["excerpt_sha256"] as? String == digest(Data(event.text.utf8)) else { throw Failure.invalid }
                    deliveredIDs.insert(Data(id.utf8))
                }
                return deliveredIDs.count
            }
            let complete = delivered == ids.count
            return sourceControlOutcome(document: document, delivered: delivered, complete: complete,
                revalidated: true, proofVersion: 3, failure: complete ? nil : "declared_sources_not_delivered",
                validationMilliseconds: milliseconds(started))
        } catch {
            return sourceControlOutcome(document: document, revalidated: false, failure: "source_control_source_body_count_invalid",
                validationMilliseconds: milliseconds(started))
        }
    }

    /// A separate offline integrity result. Failed validation never overwrites
    /// the operational completion, original debits or private answer IPC.
    private static func validateWitness(document: Document, completion: AnswerAttemptCompletion,
        directory: URL, conversationID: String,
        framing: String = ContextSourceFraming.defaultSelectionVersion) -> [String: Any] {
        guard completion.invocationStarted else {
            return witnessOutcome(events: document.events, failure: "witness_outcome_unavailable")
        }
        let validationStarted = continuousSample()
        do {
            guard let preparation = completion.preparation, let selectionID = preparation.sourceSelectionWorkID else { throw Failure.invalid }
            let delivered = try withReadOnlySnapshot(directory: directory) { database in
                let rows = try AuthorityStateKernel.rows(database,
                    "SELECT request_body,request_digest,admission_json,episode_id,project_id,conversation_id,human_event_id,episode_work_id FROM invocations WHERE id=?",
                    [.text(completion.identifiers.invocationID)])
                guard rows.count == 1, let body = rows[0][0].bytes, let admission = rows[0][2].bytes,
                      digest(body) == preparation.requestDigest, episodeIdentifierEqual(rows[0][1].string, preparation.requestDigest),
                      episodeIdentifierEqual(rows[0][3].string, completion.identifiers.episodeID),
                      episodeIdentifierEqual(rows[0][4].string, project(document.attempts[0].project_id)),
                      episodeIdentifierEqual(rows[0][5].string, conversationID),
                      episodeIdentifierEqual(rows[0][6].string, completion.identifiers.humanEventID),
                      episodeIdentifierEqual(rows[0][7].string, preparation.answerWorkID),
                      let audit = try JSONSerialization.jsonObject(with: admission) as? [String: Any],
                      audit["version"] as? Int == 3, let contextText = audit["context"] as? String,
                      let context = Data(base64Encoded: contextText), context == preparation.contextAudit,
                      let storedReceipt = audit["receipt"],
                      let contextObject = try JSONSerialization.jsonObject(with: context) as? [String: Any],
                      episodeIdentifierEqual(contextObject["selection_work_id"] as? String, selectionID),
                      episodeIdentifierEqual(contextObject["source_snapshot_sha256"] as? String, preparation.sourceSelectionDigest) else { throw Failure.invalid }
                guard let bodyObject = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let messages = bodyObject["messages"] as? [[String: String]], messages.count >= 2 else { throw Failure.invalid }
                let mandatory = ContextAssembler.mandatoryMessages(prompt: document.attempts[0].prompt,
                    system: document.configuration.system, selectionVersion: framing)
                guard messages.first?["role"] == mandatory[0].role, messages.last?["role"] == mandatory[1].role,
                      Data((messages.first?["content"] ?? "").utf8) == Data(mandatory[0].content.utf8),
                      Data((messages.last?["content"] ?? "").utf8) == Data(mandatory[1].content.utf8) else { throw Failure.invalid }
                var expectedSettings = document.configuration.settings
                expectedSettings.messagesOverride = messages
                guard try EndpointRequest.build(prompt: document.attempts[0].prompt,
                    settings: expectedSettings, conversation: Conversation()) == body else { throw Failure.invalid }
                let expectedReceipt = try object(preparation.admission)
                guard try JSONSerialization.data(withJSONObject: storedReceipt, options: [.sortedKeys, .withoutEscapingSlashes])
                    == JSONSerialization.data(withJSONObject: expectedReceipt, options: [.sortedKeys, .withoutEscapingSlashes]) else { throw Failure.invalid }
                try ContextComponentJournal.validate(database: database, invocationID: completion.identifiers.invocationID, verifySourceRanges: true)
                let selectionRows = try AuthorityStateKernel.rows(database,
                    "SELECT w.state,w.kind,w.adapter_identity,s.payload FROM episode_work w JOIN episode_request_snapshots s ON s.digest=w.snapshot_digest WHERE w.id=? AND w.episode_id=?",
                    [.text(selectionID), .text(completion.identifiers.episodeID)])
                guard selectionRows.count == 1, selectionRows[0][0].string == "completed", selectionRows[0][1].string == "sourceRead",
                      let selection = selectionRows[0][3].bytes, digest(selection) == preparation.sourceSelectionDigest,
                      let selected = try JSONSerialization.jsonObject(with: selection) as? [String: Any],
                      let recentSources = selected["recent_sources"] as? [[String: Any]],
                      let historicalSources = selected["historical_sources"] as? [[String: Any]], historicalSources.isEmpty,
                      let recentIDs = selected["recent_source_ids"] as? [String], recentIDs.count == recentSources.count,
                      ExactSourceIDs(recentIDs).count == recentIDs.count else { throw Failure.invalid }
                // Validate every original witness source, including ones lost
                // by a legitimate reduction. Gold IDs never enter this check.
                for event in document.events {
                    let source = try AuthorityStateKernel.rows(database,
                        "SELECT project_id,conversation_id,role,status,digest,byte_count,payload FROM events WHERE id=?", [.text(event.id)])
                    let bytes = Data(event.text.utf8)
                    guard source.count == 1, episodeIdentifierEqual(source[0][0].string, project(event.project_id)),
                          episodeIdentifierEqual(source[0][1].string, conversationID), source[0][2].string == (event.role == "user" ? "human" : "assistant"),
                          source[0][3].string == event.status.rawValue, source[0][4].string == digest(bytes),
                          source[0][5].integer == bytes.count, source[0][6].bytes == bytes else { throw Failure.invalid }
                }
                let originals = ExactSourceIDs(document.events.map(\.id))
                guard recentIDs.allSatisfy({ originals.contains($0) }) else { throw Failure.invalid }
                for (index, source) in recentSources.enumerated() {
                    guard let id = source["eventID"] as? String, episodeIdentifierEqual(id, recentIDs[index]),
                          let event = document.events.first(where: { episodeIdentifierEqual($0.id, id) }),
                          source["digest"] as? String == digest(Data(event.text.utf8)),
                          source["byteCount"] as? Int == event.text.utf8.count else { throw Failure.invalid }
                }
                return recentIDs.count
            }
            let complete = delivered == document.events.count
            return witnessOutcome(events: document.events, delivered: delivered, complete: complete,
                revalidated: true, proofVersion: 3, failure: complete ? nil : "witness_pack_not_delivered",
                validationMilliseconds: milliseconds(validationStarted))
        } catch {
            return witnessOutcome(events: document.events, revalidated: false, failure: "witness_source_body_count_invalid",
                validationMilliseconds: milliseconds(validationStarted))
        }
    }

    private static func withReadOnlySnapshot<T>(directory: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var raw: OpaquePointer?
        guard sqlite3_open_v2(directory.appendingPathComponent("memory.sqlite3").path, &raw, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database = raw else { if let raw { sqlite3_close(raw) }; throw Failure.io }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw Failure.io }
        defer { _ = sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        return try body(database)
    }

    private static func operationallyComplete(_ completion: AnswerAttemptCompletion) -> Bool {
        completion.episode?.state == .completed && completion.captureStatus == .complete
            && completion.captureHealthy && completion.accountingHealthy && completion.invocationStarted
            && completion.generation.failure == nil && !completion.generation.stopped
    }
    /// The coordinator of one attempt. `Session.answer` and the retrieval-arm
    /// checks share it, so the checks exercise the command's own construction.
    /// For the recent-only and hybrid arms the arguments are exactly those the
    /// command passed before `--retrieval-arm` existed (`.enabled` is the
    /// coordinator's default policy).
    private static func coordinator(document: Document, attempt: Attempt, arm: AnswerEvaluationRetrievalArm,
        owner: MemoryStore, conversationID: String, settings: GenerationSettings, limits: EpisodeLimits?,
        semantic: SemanticIndex?, runner: AnswerAttemptRunning = ModelRunner(),
        onStage: ((AnswerAttemptStage, AnswerAttemptPreparation?) -> Void)? = nil,
        onComplete: @escaping (AnswerAttemptCompletion, String) -> Void) -> AnswerAttemptCoordinator {
        AnswerAttemptCoordinator(store: owner, conversationID: conversationID,
            projectID: project(attempt.project_id), prompt: attempt.effectivePrompt,
            settings: settings, semanticIndex: semantic, retrievalStrategy: arm.retrievalStrategy, limits: limits,
            lexicalQueryUTF8Range: attempt.lexicalQueryUTF8Range,
            semanticQueryUTF8Range: document.version >= 5 ? attempt.lexicalQueryUTF8Range : nil,
            evidenceSourceIDs: attempt.evidence_source_ids,
            semanticRetrieval: arm.semanticRetrieval,
            runner: runner, onStage: onStage, onText: { _ in }, onComplete: onComplete)
    }
    private static func attemptMetadata(_ attempt: Attempt, ordinal: Int,
                                        preparationMode: PreparationMode = .ordinary) -> [String: Any] {
        var value: [String: Any] = ["ordinal": ordinal, "probe_id": attempt.probe_id, "strategy": attempt.strategy.rawValue,
            "replicate": attempt.replicate, "answer_file": String(format: "answer-%04d.txt", ordinal)]
        if preparationMode == .investigation {
            value["preparation_mode"] = preparationMode.investigates(attempt) ? "native-investigation-v1" : "ordinary-v1"
            value["memory_investigation"] = preparationMode.investigates(attempt)
        }
        return value
    }
    private static func key(_ project: String, _ conversation: String) -> String { project + "|" + conversation }
    private static func project(_ publicID: String) -> String { "answer-evaluation-public:" + publicID }
    private static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 58, 95].contains($0)
        }
    }
    private static func digest(_ data: Data) -> String { EndpointRequest.digest(data) }
    private static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    private static func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: canonical(value)) }
    private static func continuousSample() -> UInt64? {
        try? SystemEpisodeClock().now().continuousNanoseconds
    }
    private static func milliseconds(_ start: UInt64?) -> Any {
        guard let start, let now = continuousSample(), now >= start else { return NSNull() }
        return Double(now - start) / 1_000_000
    }
    private static func checkedPath(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains("."),
              !path.split(separator: "/").contains("..") else { throw Failure.arguments }
        let url = URL(fileURLWithPath: path)
        var cursor = url.deletingLastPathComponent()
        while cursor.path != "/" {
            var info = stat()
            guard lstat(cursor.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw Failure.invalid }
            cursor.deleteLastPathComponent()
        }
        return url
    }
    private static func createNewDirectory(_ url: URL) throws {
        _ = try checkedPath(url.path)
        guard mkdir(url.path, 0o700) == 0 else { throw Failure.io }
    }
    private static func readPrivateInput(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.io }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= 128 * 1024 * 1024 else { throw Failure.invalid }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { return bytes }
            if count < 0 { if errno == EINTR { continue }; throw Failure.io }
            guard bytes.count <= 128 * 1024 * 1024 - count else { throw Failure.invalid }
            bytes.append(contentsOf: buffer.prefix(count))
        }
    }
    private static func writePrivate(_ bytes: Data, _ url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.io }; defer { close(fd) }
        try bytes.withUnsafeBytes { pointer in
            var offset = 0
            while offset < pointer.count {
                let count = write(fd, pointer.baseAddress!.advanced(by: offset), pointer.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw Failure.io }
                guard count > 0 else { throw Failure.io }; offset += count
            }
        }
        guard fsync(fd) == 0 else { throw Failure.io }
    }
    /// Inspect only derived metadata after a synchronous worker drain. No
    /// source payload or query embedding is read for this construction report.
    private static func sidecarInventory(_ directory: URL) throws -> [String: Any] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(directory.appendingPathComponent("index.sqlite3").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw Failure.io }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT state,count(*),coalesce(sum(indexed_bytes),0),coalesce(sum(indexed_chunks),0),coalesce(sum(unsupported_chunks),0),coalesce(sum(next_offset),0) FROM jobs GROUP BY state", -1, &statement, nil) == SQLITE_OK else { throw Failure.io }
        defer { sqlite3_finalize(statement) }
        var states: [[String: Any]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let state = sqlite3_column_text(statement, 0) else { throw Failure.io }
            states.append(["state": String(cString: state), "sources": sqlite3_column_int64(statement, 1),
                "indexed_bytes": sqlite3_column_int64(statement, 2), "indexed_chunks": sqlite3_column_int64(statement, 3),
                "unsupported_chunks": sqlite3_column_int64(statement, 4), "offset_total": sqlite3_column_int64(statement, 5)])
        }
        return ["states": states]
    }

    /// Numeric terminal-work diagnostics only; payloads stay in the private store.
    private static func terminalWorkInventory(_ directory: URL, episodeID: String) throws -> [String: Int] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(directory.appendingPathComponent("memory.sqlite3").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw Failure.io }
        defer { sqlite3_close(db) }
        let sql = "SELECT sum(CASE WHEN state='outcomeUnknown' AND kind IN ('answer','calibration','nativeInference') THEN 1 ELSE 0 END),sum(CASE WHEN state IN ('prepared','dispatchArmed','submitted','outcomeUnknown') THEN 1 ELSE 0 END) FROM episode_work WHERE episode_id=?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw Failure.io }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, episodeID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { throw Failure.io }
        return ["unknown_output_operations": Int(sqlite3_column_int64(statement, 0)),
                "unresolved_work_count": Int(sqlite3_column_int64(statement, 1))]
    }

    private static func sourceInventory(_ directory: URL) throws -> (events: Int, bytes: Int) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(directory.appendingPathComponent("memory.sqlite3").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw Failure.io }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*),coalesce(sum(byte_count),0) FROM events", -1, &statement, nil) == SQLITE_OK else { throw Failure.io }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw Failure.io }
        return (Int(sqlite3_column_int64(statement, 0)), Int(sqlite3_column_int64(statement, 1)))
    }

    /// Foundation accepts repeated JSON keys. This scanner rejects them at
    /// every object level before Decodable or unknown-field validation runs.
    private struct UniqueKeyScanner {
        let bytes: [UInt8]
        var offset = 0
        mutating func scan() throws { try value(depth: 0); whitespace(); guard offset == bytes.count else { throw Failure.invalid } }
        mutating func whitespace() { while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 } }
        mutating func value(depth: Int) throws {
            guard depth < 64 else { throw Failure.invalid }; whitespace()
            guard offset < bytes.count else { throw Failure.invalid }
            switch bytes[offset] {
            case 123:
                offset += 1; whitespace(); var keys = Set<String>()
                if consume(125) { return }
                while true {
                    let key = try string(); guard keys.insert(key).inserted else { throw Failure.invalid }
                    whitespace(); guard consume(58) else { throw Failure.invalid }; try value(depth: depth + 1); whitespace()
                    if consume(125) { return }; guard consume(44) else { throw Failure.invalid }; whitespace()
                }
            case 91:
                offset += 1; whitespace(); if consume(93) { return }
                while true { try value(depth: depth + 1); whitespace(); if consume(93) { return }; guard consume(44) else { throw Failure.invalid } }
            case 34: _ = try string()
            default:
                let start = offset
                while offset < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[offset]) { offset += 1 }
                guard offset > start else { throw Failure.invalid }
            }
        }
        mutating func consume(_ byte: UInt8) -> Bool {
            if offset < bytes.count && bytes[offset] == byte { offset += 1; return true }; return false
        }
        mutating func string() throws -> String {
            let start = offset; guard consume(34) else { throw Failure.invalid }
            while offset < bytes.count {
                let byte = bytes[offset]; offset += 1
                if byte == 34 {
                    let wrapped = Data([91] + Array(bytes[start..<offset]) + [93])
                    guard let strings = try JSONSerialization.jsonObject(with: wrapped) as? [String], strings.count == 1 else { throw Failure.invalid }
                    return strings[0]
                }
                if byte == 92 { guard offset < bytes.count else { throw Failure.invalid }; offset += 1 }
            }
            throw Failure.invalid
        }
    }
}

// The only synthetic entry builds its own fixed sources. It cannot accept a
// caller-supplied projection, configuration pin, history or expected answer.
extension AnswerEvaluationCommand {
    static func runWitnessChecks(baseURL: String, completion: @escaping ([String: Bool]) -> Void) {
        guard LocalEndpoint.chatURL(baseURL) != nil else {
            completion(["witness_fixture_loopback_required": false]); return
        }
        do { WitnessCheckSuite(baseURL: baseURL, checks: try witnessDecodeChecks(baseURL: baseURL).merging(longMemoryDecodeChecks(baseURL: baseURL)) { _, newer in newer }
                .merging(retrievalArmChecks(baseURL: baseURL)) { _, newer in newer }, completion: completion).next() }
        catch { completion(["witness_contract_fixture_started": false]) }
    }

    private static func witnessFixture(baseURL: String, large: Bool = false, json: Bool = false) -> [String: Any] {
        let texts = large ? (0..<4).map { "Public synthetic source \($0) " + String(repeating: "x", count: 5000) }
            : ["Public synthetic decision café e\u{301}.", "Public synthetic assistant decision κ.\r\n"]
        var root: [String: Any] = ["version": 2, "split": "development", "history_id": "synthetic-witness-evidence-control",
            "events": texts.enumerated().map { index, text in
                ["id": "synthetic-witness-source-\(index)", "project_id": "synthetic-witness-project",
                 "conversation_key": "synthetic-witness-chat", "role": index % 2 == 0 ? "user" : "assistant",
                 "status": "complete", "text": text]
            }, "attempts": [["probe_id": "synthetic-witness-probe", "project_id": "synthetic-witness-project",
                "conversation_key": "synthetic-witness-chat", "prompt": "Identify the public synthetic decision.",
                "strategy": "recent_only", "replicate": 0]],
            "configuration": ["endpoint": baseURL, "model": Qwen38TextRendering.modelID,
                "system": "Use complete public synthetic sources and exact citations.", "temperature": 0,
                "seed": 42, "thinking": false, "maximum_output": 64, "context_limit": 32768, "safety_tokens": 256]]
        if json {
            root["version"] = 3
            var configuration = root["configuration"] as! [String: Any]
            configuration["response_format"] = "json_object"
            root["configuration"] = configuration
        }
        return root
    }
    private static func witnessFixtureBytes(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private static func witnessFixturePins(_ root: [String: Any], ordinary: Set<String> = []) throws -> InputPins {
        let projection = try projectionSHA256(witnessFixtureBytes(root))
        let configuration = digest(try witnessFixtureBytes(root["configuration"] as! [String: Any]))
        if root["version"] as? Int == 3 {
            return InputPins(ordinary: ordinary, witness: [], witnessConfiguration: witnessConfigurationSHA256,
                jsonWitness: [projection], jsonConfiguration: configuration)
        }
        return InputPins(ordinary: ordinary, witness: [projection], witnessConfiguration: configuration)
    }
    private static func witnessDecodeChecks(baseURL: String) throws -> [String: Bool] {
        let root = witnessFixture(baseURL: baseURL), bytes = try witnessFixtureBytes(root), pins = try witnessFixturePins(root)
        var checks: [String: Bool] = [
            "witness_contract_fixed_complete_pack_accepted": try decode(bytes, pins: pins).events.count == 2,
            "witness_contract_production_pins_disjoint": witnessCorpusProjectionSHA256.count == 9
                && witnessCorpusProjectionSHA256.isDisjoint(with: InputPins.production.ordinary),
            "witness_contract_native_configuration_pin_exact": witnessConfigurationSHA256 == "73729124226e2a729d052ea49d6f03ecced31b2b93e3beea63064ab046fa0013"
        ]
        func refused(_ value: [String: Any], using selected: InputPins) -> Bool {
            do { _ = try decode(witnessFixtureBytes(value), pins: selected); return false } catch { return true }
        }
        checks["witness_contract_synthetic_pack_not_production_authority"] = refused(root, using: .production)
        let jsonRoot = witnessFixture(baseURL: baseURL, json: true)
        let jsonPins = try witnessFixturePins(jsonRoot)
        checks["witness_contract_json_object_version_three_accepted"] = try decode(witnessFixtureBytes(jsonRoot), pins: jsonPins).configuration.settings.endpointJSONOutput
        checks["witness_contract_json_object_original_pins_reject"] = refused(jsonRoot, using: pins)
        for (name, value) in [("schema", "json_schema" as Any), ("unknown", "other" as Any),
                               ("null", NSNull() as Any), ("boolean", true as Any)] {
            var invalidRoot = jsonRoot; var invalidConfiguration = jsonRoot["configuration"] as! [String: Any]
            invalidConfiguration["response_format"] = value; invalidRoot["configuration"] = invalidConfiguration
            checks["witness_contract_json_object_invalid_format_\(name)_rejected"] = refused(invalidRoot, using: try witnessFixturePins(invalidRoot))
        }
        var legacyFormat = jsonRoot; legacyFormat["version"] = 2
        checks["witness_contract_json_object_field_rejected_in_version_two"] = refused(legacyFormat, using: try witnessFixturePins(legacyFormat))
        var unformattedV3 = root; unformattedV3["version"] = 3
        checks["witness_contract_version_three_requires_format"] = refused(unformattedV3, using: try witnessFixturePins(unformattedV3))
        var formatRoot = root
        var formatConfiguration = root["configuration"] as! [String: Any]
        formatConfiguration["system"] = "Follow the public synthetic requested JSON structure."
        formatRoot["configuration"] = formatConfiguration
        var formatPins = pins
        formatPins.formatConfiguration = digest(try witnessFixtureBytes(formatConfiguration))
        checks["witness_contract_separate_format_configuration_accepted"] = try decode(witnessFixtureBytes(formatRoot), pins: formatPins).version == 2
        checks["witness_contract_format_configuration_requires_separate_pin"] = refused(formatRoot, using: pins)
        checks["witness_contract_original_configuration_preserved_with_amendment"] = try decode(bytes, pins: formatPins).version == 2
        var changedFormat = formatConfiguration
        changedFormat["maximum_output"] = 65
        var changedFormatRoot = formatRoot; changedFormatRoot["configuration"] = changedFormat
        checks["witness_contract_format_configuration_other_settings_rejected"] = refused(changedFormatRoot, using: formatPins)
        var source = root; var events = source["events"] as! [[String: Any]]
        events[0]["text"] = "Changed public synthetic original."; source["events"] = events
        checks["witness_contract_changed_original_rejected"] = refused(source, using: pins)
        var prompt = root; var attempts = prompt["attempts"] as! [[String: Any]]
        attempts[0]["prompt"] = "Changed public synthetic probe."; prompt["attempts"] = attempts
        checks["witness_contract_changed_probe_rejected"] = refused(prompt, using: pins)
        for (name, value) in [("maximum_output", 65 as Any), ("system", "Changed synthetic host." as Any),
                              ("seed", 43 as Any), ("temperature", 0.1 as Any), ("thinking", true as Any),
                              ("context_limit", 16384 as Any), ("safety_tokens", 257 as Any),
                              ("endpoint", "http://localhost:11235/v1" as Any), ("model", "synthetic-other-model" as Any)] {
            var changed = root; var configuration = changed["configuration"] as! [String: Any]
            configuration[name] = value; changed["configuration"] = configuration
            checks["witness_contract_configuration_\(name)_change_rejected"] = refused(changed, using: pins)
        }
        // Repin only these fixed negative fixtures to exercise the independent
        // grammar, rather than obtaining rejection solely from the digest.
        for name in ["boolean_version", "unsupported_version", "hybrid", "replicate", "extra_attempt", "odd_pack", "wrong_role", "partial", "foreign_scope", "oracle"] {
            var changed = root
            var rows = changed["events"] as! [[String: Any]], tries = changed["attempts"] as! [[String: Any]]
            switch name {
            case "boolean_version": changed["version"] = true
            case "unsupported_version": changed["version"] = 4
            case "hybrid": tries[0]["strategy"] = "hybrid"
            case "replicate": tries[0]["replicate"] = 1
            case "extra_attempt": var extra = tries[0]; extra["probe_id"] = "synthetic-other-probe"; tries.append(extra)
            case "odd_pack": rows.removeLast()
            case "wrong_role": rows[1]["role"] = "user"
            case "partial": rows[1]["status"] = "partial"
            case "foreign_scope": rows[1]["project_id"] = "synthetic-other-project"
            default: changed["expected"] = "Synthetic oracle must never enter native input."
            }
            changed["events"] = rows; changed["attempts"] = tries
            checks["witness_contract_\(name)_rejected"] = refused(changed, using: try witnessFixturePins(changed))
        }
        var old = root; old["version"] = 1
        let oldProjection = try projectionSHA256(witnessFixtureBytes(old))
        let oldPins = InputPins(ordinary: [oldProjection], witness: pins.witness, witnessConfiguration: pins.witnessConfiguration)
        checks["witness_contract_version_one_preserved"] = try decode(witnessFixtureBytes(old), pins: oldPins).version == 1
        var oldConfiguration = old["configuration"] as! [String: Any]; oldConfiguration["maximum_output"] = 65
        old["configuration"] = oldConfiguration
        checks["witness_contract_version_one_configuration_allowance_preserved"] = try decode(witnessFixtureBytes(old), pins: oldPins).configuration.maximum_output == 65
        checks["witness_contract_witness_projection_rejected_by_version_one"] = refused(old, using: pins)
        let duplicate = Data(("{\"version\":2," + String(decoding: bytes.dropFirst(), as: UTF8.self)).utf8)
        do { _ = try decode(duplicate, pins: pins); checks["witness_contract_duplicate_keys_rejected"] = false }
        catch { checks["witness_contract_duplicate_keys_rejected"] = true }
        return checks
    }

    private static func longMemoryDecodeChecks(baseURL: String) throws -> [String: Bool] {
        try longMemoryDecodeChecks(baseURL: baseURL, version: 4).merging(
            longMemoryDecodeChecks(baseURL: baseURL, version: 5)) { _, newer in newer }
            .merging(longMemoryDecodeChecks(baseURL: baseURL, version: 7)) { _, newer in newer }
            .merging(sourceControlDecodeChecks(baseURL: baseURL)) { _, newer in newer }
    }

    private static func longMemoryFixturePins(_ root: [String: Any]) throws -> InputPins {
        var pins = InputPins(ordinary: [], witness: [], witnessConfiguration: witnessConfigurationSHA256)
        let projection: Set<String> = [try projectionSHA256(witnessFixtureBytes(root))]
        let configuration = digest(try witnessFixtureBytes(root["configuration"] as! [String: Any]))
        switch root["version"] as? Int {
        case 4: pins.longMemory = projection; pins.longMemoryConfiguration = configuration
        case 5: pins.semanticLongMemory = projection; pins.longMemoryConfiguration = configuration
        case 7: pins.independentLongMemory = projection; pins.independentLongMemoryConfiguration = configuration
        default: throw Failure.invalid
        }
        return pins
    }

    private static func longMemoryDecodeChecks(baseURL: String, version: Int) throws -> [String: Bool] {
        var root = witnessFixture(baseURL: baseURL)
        root["version"] = version
        if version == 7 {
            var configuration = root["configuration"] as! [String: Any]
            configuration["maximum_output"] = 1024; root["configuration"] = configuration
        }
        let time = EventSourceTime(value: "2023-07-27T18:00", precision: "minute", timezone: "unspecified",
            sourceSHA256: String(repeating: "a", count: 64), locator: "/0/haystack_dates/0", originalValue: "2023/07/27 (Thu) 18:00")
        var events = root["events"] as! [[String: Any]]
        events[0]["source_time"] = time.object; events[1]["source_time"] = time.object
        events[1]["conversation_key"] = "synthetic-other-session"
        if version == 7 {
            let secondTime = EventSourceTime(value: "2023-07-26T18:00", precision: "minute", timezone: "unspecified",
                sourceSHA256: String(repeating: "b", count: 64), locator: "/0/haystack_dates/1", originalValue: "2023/07/26 (Wed) 18:00")
            events[1]["source_time"] = secondTime.object
            events[0]["text"] = (events[0]["text"] as! String) + "\u{0} preserved scalar 界."
        }
        root["events"] = events
        var attempt = (root["attempts"] as! [[String: Any]])[0]
        if version == 7 { attempt["prompt"] = "Identify the public synthetic café e\u{301} decision 界." }
        let questionTime = EventSourceTime(value: "2023-07-28T18:00", precision: "minute", timezone: "unspecified",
            sourceSHA256: time.sourceSHA256, locator: "/0/question_date", originalValue: "2023/07/28 (Fri) 18:00")
        attempt["question_time"] = questionTime.object
        var hybrid = attempt; hybrid["strategy"] = "hybrid"
        root["attempts"] = [attempt, hybrid]
        let bytes = try witnessFixtureBytes(root)
        let pins = try longMemoryFixturePins(root)
        let document = try decode(bytes, pins: pins)
        let productionProjections = version == 4 ? longMemoryCorpusProjectionSHA256
            : version == 5 ? semanticLongMemoryCorpusProjectionSHA256 : InputPins.production.independentLongMemory
        var checks: [String: Bool] = [
            "longmem_v\(version)_paired_dates_decode": document.events.count == 2 && document.attempts.count == 2,
            "longmem_v\(version)_question_date_separate": document.attempts[0].prompt == attempt["prompt"] as? String
                && document.attempts[0].effectivePrompt == "Question Date: " + questionTime.originalValue + "\nQuestion: " + document.attempts[0].prompt,
            "longmem_v\(version)_lexical_range_is_exact_original_question": try HistoricalQueryFormulation.input(document.attempts[0].effectivePrompt,
                utf8Range: document.attempts[0].lexicalQueryUTF8Range) == document.attempts[0].prompt,
            "longmem_v\(version)_semantic_input_boundary": try HistoricalQueryFormulation.input(document.attempts[0].effectivePrompt,
                utf8Range: document.version >= 5 ? document.attempts[0].lexicalQueryUTF8Range : nil)
                    == (version >= 5 ? document.attempts[0].prompt : document.attempts[0].effectivePrompt),
            "longmem_v\(version)_timezone_remains_unknown": document.events[0].source_time?.timezone == "unspecified",
            "longmem_v\(version)_production_disjoint": longMemoryCorpusProjectionSHA256.count == 7
                && semanticLongMemoryCorpusProjectionSHA256.count == 7
                && semanticLongMemoryCorpusProjectionSHA256.isDisjoint(with: longMemoryCorpusProjectionSHA256)
                && productionProjections.count == (version == 7 ? 14 : 7)
                && productionProjections.isDisjoint(with: InputPins.production.ordinary)
                && productionProjections.isDisjoint(with: witnessCorpusProjectionSHA256)
        ]
        if version == 7 {
            let ordinaryOptions = try invocationOptions(["--answer-evaluation", "/synthetic/input.json", "--output-directory", "/synthetic/output"])
            let trialOptions = try invocationOptions(["--answer-evaluation", "/synthetic/input.json", "--output-directory", "/synthetic/output", "--investigate-memory"])
            try trialOptions.preparationMode.validate(document)
            checks["native_trial_cli_exact_optional_flag_accepted"] = ordinaryOptions.preparationMode == .ordinary
                && trialOptions.preparationMode == .investigation && trialOptions.input == ordinaryOptions.input
                && trialOptions.output == ordinaryOptions.output
            for (index, args) in [
                [] as [String], ["--answer-evaluation"],
                ["--investigate-memory", "--answer-evaluation", "/synthetic/input", "--output-directory", "/synthetic/output"],
                ["--answer-evaluation", "/synthetic/input", "--output-directory", "/synthetic/output", "--unknown"],
                ["--answer-evaluation", "/synthetic/input", "--output-directory", "/synthetic/output", "--investigate-memory", "--investigate-memory"]
            ].enumerated() {
                do { _ = try invocationOptions(args); checks["native_trial_cli_invalid_argument_\(index)_refused"] = false }
                catch { checks["native_trial_cli_invalid_argument_\(index)_refused"] = true }
            }
            let recentAttempt = document.attempts[0], hybridAttempt = document.attempts[1]
            checks["native_trial_cli_recent_control_uses_ordinary_settings"] = !PreparationMode.investigation
                .settings(document.configuration, attempt: recentAttempt).investigateMemory
            checks["native_trial_cli_only_hybrid_uses_investigation_settings"] = PreparationMode.investigation
                .settings(document.configuration, attempt: hybridAttempt).investigateMemory
                && !PreparationMode.ordinary.settings(document.configuration, attempt: hybridAttempt).investigateMemory
            checks["native_trial_cli_skips_semantic_construction_only_for_native"] = !PreparationMode.investigation
                .constructsSemanticIndex(version: version, attempt: hybridAttempt)
                && PreparationMode.ordinary.constructsSemanticIndex(version: version, attempt: hybridAttempt)
                && !PreparationMode.investigation.constructsSemanticIndex(version: version, attempt: recentAttempt)
            let recentMetadata = attemptMetadata(recentAttempt, ordinal: 0, preparationMode: .investigation)
            let nativeMetadata = attemptMetadata(hybridAttempt, ordinal: 1, preparationMode: .investigation)
            checks["native_trial_cli_per_attempt_mode_identity"] = recentMetadata["memory_investigation"] as? Bool == false
                && nativeMetadata["memory_investigation"] as? Bool == true
                && recentMetadata["preparation_mode"] as? String == "ordinary-v1"
                && nativeMetadata["preparation_mode"] as? String == "native-investigation-v1"
            checks["native_trial_cli_ordinary_metadata_contract_unchanged"] = Set(attemptMetadata(hybridAttempt, ordinal: 1).keys)
                == ["ordinal", "probe_id", "strategy", "replicate", "answer_file"]
            checks["longmem_v7_production_independent_from_all_prior_versions"] = productionProjections
                .isDisjoint(with: longMemoryCorpusProjectionSHA256.union(semanticLongMemoryCorpusProjectionSHA256)
                    .union(completeSourceLongMemoryCorpusProjectionSHA256).union(jsonObjectCorpusProjectionSHA256))
            checks["longmem_v7_synthetic_configuration_separate"] = document.configuration.maximum_output == 1024
                && pins.independentLongMemoryConfiguration != pins.longMemoryConfiguration
            checks["longmem_v7_production_configuration_independent"] = independentLongMemoryConfigurationSHA256
                != longMemoryConfigurationSHA256 && InputPins.production.independentLongMemoryConfiguration
                    == independentLongMemoryConfigurationSHA256
        }
        func refused(_ changed: [String: Any], using selected: InputPins) -> Bool {
            do { _ = try decode(witnessFixtureBytes(changed), pins: selected); return false } catch { return true }
        }
        checks["longmem_v\(version)_synthetic_not_production_authority"] = refused(root, using: .production)
        if version == 7 {
            var hundredRoot = root
            hundredRoot["version"] = 8
            hundredRoot["attempts"] = [hybrid]
            var hundredPins = pins
            hundredPins.hundredLongMemory = [try projectionSHA256(witnessFixtureBytes(hundredRoot))]
            hundredPins.hundredLongMemoryConfiguration = pins.independentLongMemoryConfiguration
            let hundredDocument = try decode(witnessFixtureBytes(hundredRoot), pins: hundredPins)
            try PreparationMode.investigation.validate(hundredDocument)
            checks["longmem_v8_exact_single_hybrid_investigation_accepted"] = hundredDocument.attempts.count == 1
                && hundredDocument.attempts[0].strategy == .hybrid
                && PreparationMode.investigation.settings(hundredDocument.configuration, attempt: hundredDocument.attempts[0]).investigateMemory
            do { try PreparationMode.ordinary.validate(hundredDocument); checks["longmem_v8_ordinary_mode_refused"] = false }
            catch { checks["longmem_v8_ordinary_mode_refused"] = true }
            checks["longmem_v8_prior_projection_authority_refused"] = refused(hundredRoot, using: pins)
            checks["longmem_v8_hundred_projection_authority_cannot_enable_v7"] = refused(root, using: InputPins(
                ordinary: [], witness: [], witnessConfiguration: "",
                hundredLongMemory: [try projectionSHA256(bytes)],
                hundredLongMemoryConfiguration: pins.independentLongMemoryConfiguration))
            checks["longmem_v8_production_has_exact_100_separate_pins"] = hundredLongMemoryCorpusProjectionSHA256.count == 100
                && hundredLongMemoryCorpusProjectionSHA256.isDisjoint(with: independentLongMemoryCorpusProjectionSHA256)
                && hundredLongMemoryCorpusProjectionSHA256.isDisjoint(with: longMemoryCorpusProjectionSHA256)
            for kind in ["paired", "recent_only", "replicate", "annotation", "configuration"] {
                var changed = hundredRoot
                switch kind {
                case "paired": changed["attempts"] = [attempt, hybrid]
                case "recent_only": changed["attempts"] = [attempt]
                case "replicate": var row = hybrid; row["replicate"] = 1; changed["attempts"] = [row]
                case "annotation": var row = hybrid; row["answer"] = "Scorer-only synthetic value"; changed["attempts"] = [row]
                default: var c = root["configuration"] as! [String: Any]; c["maximum_output"] = 512; changed["configuration"] = c
                }
                var repinned = hundredPins
                repinned.hundredLongMemory = [try projectionSHA256(witnessFixtureBytes(changed))]
                checks["longmem_v8_repin_\(kind)_refused"] = refused(changed, using: repinned)
            }
        }
        for kind in ["event_date_null", "question_date_null", "oracle", "changed_source", "changed_question", "legacy", "other_longmem_version", "unsupported_version", "configuration"] {
            var changed = root
            switch kind {
            case "event_date_null": var rows = events; rows[0]["source_time"] = NSNull(); changed["events"] = rows
            case "question_date_null": var rows = [attempt, hybrid]; rows[0]["question_time"] = NSNull(); changed["attempts"] = rows
            case "oracle": changed["answer"] = "Synthetic scorer only"
            case "changed_source": var rows = events; rows[0]["text"] = "Changed synthetic source"; changed["events"] = rows
            case "changed_question": var rows = [attempt, hybrid]; rows[0]["prompt"] = "Changed synthetic question"; changed["attempts"] = rows
            case "legacy": changed["version"] = 1
            case "other_longmem_version": changed["version"] = version == 4 ? 5 : 4
            case "unsupported_version": changed["version"] = 8
            default: var c = root["configuration"] as! [String: Any]; c["maximum_output"] = 129; changed["configuration"] = c
            }
            checks["longmem_v\(version)_" + kind + "_refused"] = refused(changed, using: pins)
        }
        // Re-pin a malformed synthetic projection to test grammar separately from its checksum.
        var malformed = root; var badEvents = events; var invalidTime = time.object
        invalidTime["original_value"] = "2023/02/30 (Thu) 18:00"; badEvents[0]["source_time"] = invalidTime; malformed["events"] = badEvents
        let malformedPins = try longMemoryFixturePins(malformed)
        checks["longmem_v\(version)_invalid_date_grammar_refused"] = refused(malformed, using: malformedPins)
        if version == 7 {
            for kind in ["source_id", "source_role", "source_status", "source_date", "question_date", "session", "project", "source_order", "attempt_order", "replicate", "strategy", "declared_sources", "attempt_oracle", "event_oracle"] {
                var changed = root
                switch kind {
                case "source_id": var rows = events; rows[0]["id"] = "synthetic-other-source"; changed["events"] = rows
                case "source_role": var rows = events; rows[0]["role"] = "assistant"; changed["events"] = rows
                case "source_status": var rows = events; rows[0]["status"] = "partial"; changed["events"] = rows
                case "source_date": var rows = events; var date = time.object; date["locator"] = "/1/haystack_dates/0"; rows[0]["source_time"] = date; changed["events"] = rows
                case "question_date": var rows = [attempt, hybrid]; var date = questionTime.object; date["locator"] = "/1/question_date"; rows[0]["question_time"] = date; changed["attempts"] = rows
                case "session": var rows = events; rows[1]["conversation_key"] = attempt["conversation_key"]; changed["events"] = rows
                case "project": var rows = events; rows[0]["project_id"] = "synthetic-other-project"; changed["events"] = rows
                case "source_order": changed["events"] = Array(events.reversed())
                case "attempt_order": changed["attempts"] = [hybrid, attempt]
                case "replicate": var rows = [attempt, hybrid]; rows[1]["replicate"] = 1; changed["attempts"] = rows
                case "strategy": var rows = [attempt, hybrid]; rows[1]["strategy"] = "recent_only"; changed["attempts"] = rows
                case "declared_sources": var rows = [attempt, hybrid]; rows[1]["evidence_source_ids"] = [events[0]["id"] as! String]; changed["attempts"] = rows
                case "attempt_oracle": var rows = [attempt, hybrid]; rows[1]["has_answer"] = true; changed["attempts"] = rows
                default: var rows = events; rows[0]["answer"] = "Synthetic scorer only"; changed["events"] = rows
                }
                checks["longmem_v7_frozen_\(kind)_change_refused"] = refused(changed, using: pins)
            }
            for otherVersion in [4, 5, 6] {
                var crossPins = pins
                let projection: Set<String> = [try projectionSHA256(bytes)]
                crossPins.independentLongMemory = []
                if otherVersion == 4 { crossPins.longMemory = projection }
                else if otherVersion == 5 { crossPins.semanticLongMemory = projection }
                else { crossPins.completeSourceLongMemory = projection }
                crossPins.longMemoryConfiguration = pins.independentLongMemoryConfiguration
                checks["longmem_v7_version_\(otherVersion)_pins_cannot_authorize"] = refused(root, using: crossPins)
                var changedVersion = root; changedVersion["version"] = otherVersion
                var independentPins = pins
                independentPins.independentLongMemory = [try projectionSHA256(witnessFixtureBytes(changedVersion))]
                checks["longmem_v7_independent_pins_cannot_authorize_version_\(otherVersion)"] = refused(changedVersion, using: independentPins)
            }
            var crossConfiguration = pins
            crossConfiguration.longMemoryConfiguration = pins.independentLongMemoryConfiguration
            crossConfiguration.independentLongMemoryConfiguration = nil
            checks["longmem_v7_legacy_configuration_pin_cannot_authorize"] = refused(root, using: crossConfiguration)
            for kind in ["event_date_null", "question_date_null", "source_status", "source_project", "attempt_order", "replicate", "declared_sources"] {
                var changed = root
                switch kind {
                case "event_date_null": var rows = events; rows[0]["source_time"] = NSNull(); changed["events"] = rows
                case "question_date_null": var rows = [attempt, hybrid]; rows[0]["question_time"] = NSNull(); changed["attempts"] = rows
                case "source_status": var rows = events; rows[0]["status"] = "partial"; changed["events"] = rows
                case "source_project": var rows = events; rows[0]["project_id"] = "synthetic-other-project"; changed["events"] = rows
                case "attempt_order": changed["attempts"] = [hybrid, attempt]
                case "replicate": var rows = [attempt, hybrid]; rows[1]["replicate"] = 1; changed["attempts"] = rows
                default: var rows = [attempt, hybrid]; rows[1]["evidence_source_ids"] = [events[0]["id"] as! String]; changed["attempts"] = rows
                }
                checks["longmem_v7_repin_malformed_\(kind)_refused"] = refused(changed, using: try longMemoryFixturePins(changed))
            }
            var changedConfiguration = root
            var configuration = root["configuration"] as! [String: Any]
            configuration["maximum_output"] = 512; changedConfiguration["configuration"] = configuration
            checks["longmem_v7_output_512_cannot_use_independent_1024_pin"] = refused(changedConfiguration, using: pins)
            for malformedVersion in [true as Any, 7.5 as Any, 0 as Any, 8 as Any] {
                var changed = root; changed["version"] = malformedVersion
                var repinned = pins; repinned.independentLongMemory = [try projectionSHA256(witnessFixtureBytes(changed))]
                let name = malformedVersion is Bool ? "boolean" : (malformedVersion as? Double == 7.5 ? "fractional" : "out_of_range_\(malformedVersion)")
                checks["longmem_v7_repin_malformed_version_\(name)_refused"] = refused(changed, using: repinned)
            }
        }
        if version != 7 {
            do { try PreparationMode.investigation.validate(document); checks["native_trial_cli_version_\(version)_refused"] = false }
            catch { checks["native_trial_cli_version_\(version)_refused"] = true }
            try PreparationMode.ordinary.validate(document)
            checks["native_trial_cli_version_\(version)_ordinary_accepted"] = true
        }
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw Failure.io }
        let temporaryRoot = String(cString: resolved); free(resolved)
        let directory = URL(fileURLWithPath: temporaryRoot, isDirectory: true).appendingPathComponent("boros-longmem-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try MemoryStore(directory: directory.appendingPathComponent("store"))
        let conversations = try ingestEvents(document, into: owner)
        checks["longmem_v\(version)_original_session_boundaries_preserved"] = conversations.count == 2
        checks["longmem_v\(version)_exact_dates_and_text_ingested"] = try document.events.allSatisfy { event in
            let chat = conversations[key(event.project_id, event.conversation_key)]!
            return try owner.events(conversationID: chat).contains { stored in
                stored.id == event.id && Data(stored.text.utf8) == Data(event.text.utf8) && stored.sourceTime == event.source_time
            }
        }
        let archive = directory.appendingPathComponent("archive"), restored = directory.appendingPathComponent("restored")
        _ = try BackupArchive.create(from: owner, at: archive)
        _ = try BackupArchive.restore(from: archive, to: restored, authority: .unmanagedNoDeletion)
        let reopened = try MemoryStore(directory: restored)
        checks["longmem_v\(version)_dates_survive_attempt_checkpoint"] = try document.events.allSatisfy { event in
            try reopened.sourceReference(eventID: event.id, projectID: project(event.project_id))?.sourceTime == event.source_time
        }
        if version == 7 {
            let references = try document.events.map { event -> MemorySourceReference in
                guard let reference = try owner.sourceReference(eventID: event.id, projectID: project(event.project_id)) else { throw Failure.invalid }
                return reference
            }
            let restoredReferences = try document.events.map { event -> MemorySourceReference in
                guard let reference = try reopened.sourceReference(eventID: event.id, projectID: project(event.project_id)) else { throw Failure.invalid }
                return reference
            }
            checks["longmem_v7_checkpoint_preserves_exact_source_identity_order_and_metadata"] = references == restoredReferences
                && zip(references, references.dropFirst()).allSatisfy { pair in pair.0.sequence < pair.1.sequence }
                && zip(document.events, restoredReferences).allSatisfy { pair in
                    let (event, reference) = pair
                    return Data(reference.eventID.utf8) == Data(event.id.utf8)
                        && reference.projectID == project(event.project_id)
                        && reference.conversationID == conversations[key(event.project_id, event.conversation_key)]
                        && reference.status == .complete && reference.role == (event.role == "user" ? .human : .assistant)
                        && reference.byteCount == event.text.utf8.count && reference.digest == digest(Data(event.text.utf8))
                }
            checks["longmem_v7_checkpoint_preserves_exact_original_source_bodies"] = try document.events.allSatisfy { event in
                let chat = conversations[key(event.project_id, event.conversation_key)]!
                return try reopened.events(conversationID: chat).contains { stored in
                    Data(stored.id.utf8) == Data(event.id.utf8) && Data(stored.text.utf8) == Data(event.text.utf8)
                        && stored.sourceTime == event.source_time && stored.status == .complete
                        && stored.role == (event.role == "user" ? .human : .assistant)
                }
            }
            let originalQuestion = document.attempts[0].effectivePrompt
            let body = try EndpointRequest.build(prompt: originalQuestion, settings: document.configuration.settings, conversation: Conversation())
            guard let request = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let messages = request["messages"] as? [[String: String]] else { throw Failure.invalid }
            checks["longmem_v7_request_encoding_preserves_full_dated_question_and_output_cap"] = request["max_tokens"] as? Int == 1024
                && messages.last?["role"] == "user" && (messages.last?["content"]).map { Data($0.utf8) } == Data(originalQuestion.utf8)
                && document.attempts.allSatisfy { Data($0.effectivePrompt.utf8) == Data(originalQuestion.utf8) }
            let chat = conversations[key(document.attempts[0].project_id, document.attempts[0].conversation_key)]!
            let accepted = try reopened.append(conversationID: chat, role: .human, text: originalQuestion,
                status: .complete, turnID: "synthetic-independent-question-turn", eventID: "synthetic-independent-question")
            let questionArchive = directory.appendingPathComponent("question-archive"), questionRestored = directory.appendingPathComponent("question-restored")
            _ = try BackupArchive.create(from: reopened, at: questionArchive)
            _ = try BackupArchive.restore(from: questionArchive, to: questionRestored, authority: .unmanagedNoDeletion)
            let questionOwner = try MemoryStore(directory: questionRestored)
            let storedQuestion = try questionOwner.events(conversationID: chat).first { $0.id == accepted.id }
            let restoredQuestionReference = try questionOwner.sourceReference(eventID: accepted.id, projectID: project(document.attempts[0].project_id))
            let acceptedQuestionReference = try reopened.sourceReference(eventID: accepted.id, projectID: project(document.attempts[0].project_id))
            checks["longmem_v7_checkpoint_preserves_exact_full_dated_accepted_question"] = storedQuestion.map { Data($0.text.utf8) } == Data(originalQuestion.utf8)
                && restoredQuestionReference == acceptedQuestionReference
            checks["longmem_v7_checkpoint_question_reencodes_same_request_body"] = try EndpointRequest.build(prompt: storedQuestion?.text ?? "",
                settings: document.configuration.settings, conversation: Conversation()) == body
        }
        return checks
    }

    private static func sourceControlFixture(baseURL: String, reduced: Bool = false) -> [String: Any] {
        var root = witnessFixture(baseURL: baseURL)
        root["version"] = 6; root["history_id"] = "synthetic-complete-source-control"
        let time = EventSourceTime(value: "2023-07-27T18:00", precision: "minute", timezone: "unspecified",
            sourceSHA256: String(repeating: "d", count: 64), locator: "/synthetic/source/date", originalValue: "2023/07/27 (Thu) 18:00")
        let count = reduced ? 16 : 3
        let events: [[String: Any]] = (0..<count).map { index in
            ["id": "synthetic-declared-\(index)", "project_id": "synthetic-witness-project",
             "conversation_key": index == 0 ? "synthetic-witness-chat" : "synthetic-archive-\(index % 2)",
             "role": index == 2 ? "assistant" : "user", "status": "complete",
             "text": reduced ? "Public synthetic source \(index) " + String(repeating: "界", count: 1300)
                : "Public synthetic source \(index) café\u{0} e\u{301} retained.", "source_time": time.object]
        }
        root["events"] = events
        var attempt = (root["attempts"] as! [[String: Any]])[0]
        attempt["strategy"] = "hybrid"; attempt["question_time"] = time.object
        attempt["evidence_source_ids"] = [events[1]["id"] as! String, events[0]["id"] as! String]
            + events.dropFirst(2).map { $0["id"] as! String }
        root["attempts"] = [attempt]
        if reduced {
            var configuration = root["configuration"] as! [String: Any]
            configuration["context_limit"] = 3200; root["configuration"] = configuration
        }
        return root
    }

    /// `--retrieval-arm` contracts that need no endpoint: option parsing,
    /// refusal before any output exists, per-attempt resolution, and the
    /// ordinary Send host index. Selection equivalence with the retrieval
    /// harness is checked across binaries by scripts/test_ordinary_send_arm.py.
    private static func retrievalArmChecks(baseURL: String) throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        let base = ["--answer-evaluation", "/synthetic/input.json", "--output-directory", "/synthetic/output"]
        let plain = try invocationOptions(base)
        let selected = try invocationOptions(base + ["--retrieval-arm", "ordinary_send"])
        let combined = try invocationOptions(base + ["--context-framing", ContextSourceFraming.quotedSelectionVersion,
            "--retrieval-arm", "ordinary_send", "--attempt", "1"])
        checks["retrieval_arm_cli_default_is_declared_strategy"] = plain.retrievalArm == nil
        checks["retrieval_arm_cli_ordinary_send_accepted"] = selected.retrievalArm == .ordinarySend
            && selected.preparationMode == .ordinary && selected.componentPolicy == nil && !selected.framingPinned
        checks["retrieval_arm_cli_combines_with_framing_and_attempt"] = combined.retrievalArm == .ordinarySend
            && combined.onlyAttempt == 1 && combined.framingPinned
        for (index, extra) in [["--retrieval-arm", "hybrid"], ["--retrieval-arm", "recent_only"], ["--retrieval-arm", "lexical"],
                               ["--retrieval-arm", "ordinary-send"], ["--retrieval-arm"],
                               ["--retrieval-arm", "ordinary_send", "--retrieval-arm", "ordinary_send"]].enumerated() {
            do { _ = try invocationOptions(base + extra); checks["retrieval_arm_cli_invalid_\(index)_refused"] = false }
            catch { checks["retrieval_arm_cli_invalid_\(index)_refused"] = true }
        }
        do {
            _ = try invocationOptions(base + ["--investigate-memory", "--retrieval-arm", "ordinary_send"])
            checks["retrieval_arm_cli_refused_with_investigation"] = false
        } catch { checks["retrieval_arm_cli_refused_with_investigation"] = true }
        checks["retrieval_arm_selectable_only_while_policy_disables_semantic"] = AnswerEvaluationRetrievalArm.ordinarySendSelectable
            == (SemanticRetrievalPolicy.ordinarySend == .disabledByPolicy)
            && AnswerEvaluationRetrievalArm.selectable == [.ordinarySend]

        // Resolution: without the flag every attempt keeps its declared
        // strategy, the coordinator default policy and the explicit build.
        let unchanged = ContextRetrievalStrategy.allCases.allSatisfy { strategy in
            let arm = AnswerEvaluationRetrievalArm.resolve(declared: strategy, selected: nil)
            return arm.retrievalStrategy == strategy && arm.semanticRetrieval == .enabled
                && arm.buildsSemanticIndex == (strategy == .hybrid) && arm.rawValue == strategy.rawValue
        }
        checks["retrieval_arm_existing_arms_unchanged"] = unchanged
        let recent = AnswerEvaluationRetrievalArm.resolve(declared: .recentOnly, selected: .ordinarySend)
        let ordinary = AnswerEvaluationRetrievalArm.resolve(declared: .hybrid, selected: .ordinarySend)
        checks["retrieval_arm_ordinary_send_replaces_only_hybrid_attempts"] = recent == .recentOnly && ordinary == .ordinarySend
        checks["retrieval_arm_ordinary_send_is_gui_send_configuration"] = ordinary.retrievalStrategy == .hybrid
            && ordinary.semanticRetrieval == SemanticRetrievalPolicy.ordinarySend && !ordinary.buildsSemanticIndex

        // The host index: the GUI's entry point opens nothing under the policy.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boros-retrieval-arm-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MemoryStore(directory: directory)
        var opened = 0
        let host = try ordinary.hostIndex(store: store) { _ in opened += 1; throw SemanticError.invalid }
        let others = try [AnswerEvaluationRetrievalArm.recentOnly, .hybrid].map { arm in
            try arm.hostIndex(store: store) { _ in opened += 1; throw SemanticError.invalid }
        }
        let window = try store.backgroundBudgetSnapshot().window
        checks["retrieval_arm_ordinary_send_builds_and_passes_no_index"] = host == nil && others.allSatisfy { $0 == nil } && opened == 0
            && !FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("semantic", isDirectory: true).path)
            && window == nil
        let admitted = AnswerAttemptCoordinator(store: store, conversationID: "unused", projectID: "unused", prompt: "unused",
            settings: GenerationSettings(), semanticIndex: nil, semanticRetrieval: ordinary.semanticRetrieval,
            onText: { _ in }, onComplete: { _, _ in })
        checks["retrieval_arm_ordinary_send_coordinator_receives_no_index"] = !admitted.preparationReceivesSemanticIndex

        // Refusal happens after decoding and before the output directory.
        func accepts(_ document: Document, _ options: InvocationOptions) -> Bool {
            do { try validateRetrievalArm(options, document); return true } catch { return false }
        }
        var paired = witnessFixture(baseURL: baseURL)
        paired["version"] = 7
        let time = EventSourceTime(value: "2023-07-27T18:00", precision: "minute", timezone: "unspecified",
            sourceSHA256: String(repeating: "e", count: 64), locator: "/synthetic/retrieval-arm/date", originalValue: "2023/07/27 (Thu) 18:00")
        paired["events"] = (paired["events"] as! [[String: Any]]).map { var event = $0; event["source_time"] = time.object; return event }
        var question = (paired["attempts"] as! [[String: Any]])[0]
        question["question_time"] = time.object
        var hybrid = question; hybrid["strategy"] = "hybrid"
        paired["attempts"] = [question, hybrid]
        let pairedDocument = try decode(witnessFixtureBytes(paired), pins: longMemoryFixturePins(paired))
        let witness = witnessFixture(baseURL: baseURL)
        let witnessDocument = try decode(witnessFixtureBytes(witness), pins: witnessFixturePins(witness))
        let control = sourceControlFixture(baseURL: baseURL)
        let controlDocument = try decode(witnessFixtureBytes(control), pins: sourceControlFixturePins(control))
        var recentOnly = selected; recentOnly.onlyAttempt = 0
        var hybridOnly = selected; hybridOnly.onlyAttempt = 1
        checks["retrieval_arm_paired_input_accepted"] = accepts(pairedDocument, selected) && accepts(pairedDocument, hybridOnly)
        checks["retrieval_arm_refused_when_no_selected_hybrid_attempt"] = !accepts(pairedDocument, recentOnly)
            && !accepts(witnessDocument, selected)
        checks["retrieval_arm_refused_for_declared_source_control"] = !accepts(controlDocument, selected)
        checks["retrieval_arm_absent_flag_accepts_every_input"] = accepts(pairedDocument, plain) && accepts(witnessDocument, plain)
            && accepts(controlDocument, plain)
        return checks
    }

    private static func sourceControlFixturePins(_ root: [String: Any]) throws -> InputPins {
        var pins = InputPins(ordinary: [], witness: [], witnessConfiguration: witnessConfigurationSHA256)
        pins.completeSourceLongMemory = [try projectionSHA256(witnessFixtureBytes(root))]
        pins.longMemoryConfiguration = digest(try witnessFixtureBytes(root["configuration"] as! [String: Any]))
        return pins
    }

    private static func sourceControlDecodeChecks(baseURL: String) throws -> [String: Bool] {
        let root = sourceControlFixture(baseURL: baseURL), pins = try sourceControlFixturePins(root)
        let document = try decode(witnessFixtureBytes(root), pins: pins), attempt = document.attempts[0]
        var checks: [String: Bool] = [
            "source_control_v6_one_hybrid_attempt_and_exact_ids_decode": document.version == 6 && document.attempts.count == 1
                && attempt.strategy == .hybrid && attempt.replicate == 0
                && attempt.evidence_source_ids == ["synthetic-declared-1", "synthetic-declared-0", "synthetic-declared-2"],
            "source_control_v6_full_prompt_date_and_question_ranges_preserved": try HistoricalQueryFormulation.input(attempt.effectivePrompt,
                utf8Range: attempt.lexicalQueryUTF8Range) == attempt.prompt
                && attempt.effectivePrompt == "Question Date: " + attempt.question_time!.originalValue + "\nQuestion: " + attempt.prompt,
            "source_control_v6_cross_conversation_non_alternating_originals_accepted": Set(document.events.map(\.conversation_key)).count == 3
                && document.events[0].role == "user" && document.events[1].role == "user",
            "source_control_v6_production_pins_separate_from_all_prior_versions": completeSourceLongMemoryCorpusProjectionSHA256.count == 6
                && completeSourceLongMemoryCorpusProjectionSHA256.isDisjoint(with: longMemoryCorpusProjectionSHA256)
                && completeSourceLongMemoryCorpusProjectionSHA256.isDisjoint(with: semanticLongMemoryCorpusProjectionSHA256)
                && completeSourceLongMemoryCorpusProjectionSHA256.isDisjoint(with: witnessCorpusProjectionSHA256)
                && completeSourceLongMemoryCorpusProjectionSHA256.isDisjoint(with: InputPins.production.ordinary)
                && completeSourceLongMemoryCorpusProjectionSHA256.isDisjoint(with: jsonObjectCorpusProjectionSHA256)
        ]
        func refused(_ changed: [String: Any], using selected: InputPins) -> Bool {
            do { _ = try decode(witnessFixtureBytes(changed), pins: selected); return false } catch { return true }
        }
        checks["source_control_v6_synthetic_not_production_authority"] = refused(root, using: .production)
        for kind in ["missing_ids", "empty_ids", "duplicate_ids", "too_many_ids", "unknown_id", "boolean_id", "recent_only", "replicate", "extra_attempt",
                     "empty_source", "oversized_source", "partial_source", "foreign_project", "missing_source_date", "missing_question_date",
                     "invalid_calendar", "root_oracle", "attempt_oracle", "event_oracle"] {
            var changed = root, events = root["events"] as! [[String: Any]], attempts = root["attempts"] as! [[String: Any]]
            switch kind {
            case "missing_ids": attempts[0].removeValue(forKey: "evidence_source_ids")
            case "empty_ids": attempts[0]["evidence_source_ids"] = [] as [String]
            case "duplicate_ids": attempts[0]["evidence_source_ids"] = ["synthetic-declared-0", "synthetic-declared-0"]
            case "too_many_ids": attempts[0]["evidence_source_ids"] = (0..<17).map { "synthetic-declared-\($0)" }
            case "unknown_id": attempts[0]["evidence_source_ids"] = ["synthetic-unknown"]
            case "boolean_id": attempts[0]["evidence_source_ids"] = [true]
            case "recent_only": attempts[0]["strategy"] = "recent_only"
            case "replicate": attempts[0]["replicate"] = 1
            case "extra_attempt": var extra = attempts[0]; extra["probe_id"] = "synthetic-extra"; attempts.append(extra)
            case "empty_source": events[0]["text"] = ""
            case "oversized_source": events[0]["text"] = String(repeating: "x", count: 4097)
            case "partial_source": events[0]["status"] = "partial"
            case "foreign_project": events[0]["project_id"] = "synthetic-foreign"
            case "missing_source_date": events[0]["source_time"] = NSNull()
            case "missing_question_date": attempts[0]["question_time"] = NSNull()
            case "invalid_calendar": var time = events[0]["source_time"] as! [String: Any]; time["value"] = "2023-02-30"; events[0]["source_time"] = time
            case "root_oracle": changed["answer"] = "Public synthetic scorer-only reference"
            case "attempt_oracle": attempts[0]["has_answer"] = true
            default: events[0]["oracle"] = true
            }
            changed["events"] = events; changed["attempts"] = attempts
            checks["source_control_v6_\(kind)_grammar_refused"] = refused(changed, using: try sourceControlFixturePins(changed))
        }
        for kind in ["text", "source_date", "question", "question_date", "event_order", "declared_order", "configuration", "old_version"] {
            var changed = root, events = root["events"] as! [[String: Any]], attempts = root["attempts"] as! [[String: Any]]
            switch kind {
            case "text": events[0]["text"] = "Changed public synthetic source"
            case "source_date": var time = events[0]["source_time"] as! [String: Any]; time["locator"] = "/synthetic/changed"; events[0]["source_time"] = time
            case "question": attempts[0]["prompt"] = "Changed public synthetic question"
            case "question_date": var time = attempts[0]["question_time"] as! [String: Any]; time["locator"] = "/synthetic/changed"; attempts[0]["question_time"] = time
            case "event_order": events.swapAt(0, 1)
            case "declared_order": attempts[0]["evidence_source_ids"] = ["synthetic-declared-0", "synthetic-declared-1", "synthetic-declared-2"]
            case "configuration": var configuration = root["configuration"] as! [String: Any]; configuration["maximum_output"] = 65; changed["configuration"] = configuration
            default: changed["version"] = 5
            }
            changed["events"] = events; changed["attempts"] = attempts
            checks["source_control_v6_frozen_\(kind)_change_refused"] = refused(changed, using: pins)
        }
        let unknown = sourceControlOutcome(document: document, failure: "source_control_outcome_unavailable")
        checks["source_control_v6_unavailable_retains_counts_without_sufficiency_or_answer_claim"] = unknown["declared_source_count"] as? Int == 3
            && unknown["declared_source_bytes"] as? Int == document.events.reduce(0, { $0 + $1.text.utf8.count })
            && unknown["complete_declared_sources_delivered"] is NSNull && unknown["source_body_count_revalidated"] is NSNull
            && unknown["delivered_source_count"] is NSNull && unknown["input_proof_version"] is NSNull
            && unknown["semantic_sufficiency"] == nil && unknown["answer_correct"] == nil
        return checks
    }

    private final class WitnessCheckSuite {
        let baseURL: String, completion: ([String: Bool]) -> Void
        var checks: [String: Bool], cases = ["complete", "reduced", "stopped", "json_complete"]
        var current: WitnessCheckAttempt?
        init(baseURL: String, checks: [String: Bool], completion: @escaping ([String: Bool]) -> Void) {
            self.baseURL = baseURL; self.checks = checks; self.completion = completion
        }
        func next() {
            guard !cases.isEmpty else { SourceControlCheckSuite(baseURL: baseURL, checks: checks, completion: completion).next(); return }
            let kind = cases.removeFirst()
            do {
                let attempt = try WitnessCheckAttempt(baseURL: baseURL, kind: kind) { [self] result in
                    checks.merge(result) { _, latest in latest }; current = nil
                    // Let the attempt callback return and release its private
                    // fixture before the final completion can exit the CLI.
                    DispatchQueue.main.async { [self] in next() }
                }
                current = attempt; attempt.start()
            } catch { checks["witness_\(kind)_fixture_started"] = false; next() }
        }
    }
    private final class SourceControlCheckSuite {
        let baseURL: String, completion: ([String: Bool]) -> Void
        var checks: [String: Bool], cases = ["complete", "reduced", "stopped"]
        var current: SourceControlCheckAttempt?
        init(baseURL: String, checks: [String: Bool], completion: @escaping ([String: Bool]) -> Void) {
            self.baseURL = baseURL; self.checks = checks; self.completion = completion
        }
        func next() {
            guard !cases.isEmpty else { completion(checks); return }
            let kind = cases.removeFirst()
            do {
                let attempt = try SourceControlCheckAttempt(baseURL: baseURL, kind: kind) { [self] result in
                    checks.merge(result) { _, latest in latest }; current = nil
                    DispatchQueue.main.async { [self] in next() }
                }
                current = attempt; attempt.start()
            } catch { checks["source_control_\(kind)_fixture_started"] = false; next() }
        }
    }

    private final class SourceControlCheckAttempt {
        let document: Document, kind: String, directory: URL, store: MemoryStore, conversations: [String: String]
        let completion: ([String: Bool]) -> Void
        var coordinator: AnswerAttemptCoordinator?
        init(baseURL: String, kind: String, completion: @escaping ([String: Bool]) -> Void) throws {
            self.kind = kind; self.completion = completion
            let root = sourceControlFixture(baseURL: baseURL, reduced: kind == "reduced")
            document = try decode(witnessFixtureBytes(root), pins: sourceControlFixturePins(root))
            guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw Failure.io }
            let path = String(cString: resolved); free(resolved)
            directory = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("boros-source-control-check-" + UUID().uuidString)
            let baseline = try MemoryStore(directory: directory.appendingPathComponent("baseline"))
            conversations = try ingestEvents(document, into: baseline)
            let archive = directory.appendingPathComponent("archive"), restored = directory.appendingPathComponent("restored")
            _ = try BackupArchive.create(from: baseline, at: archive)
            _ = try BackupArchive.restore(from: archive, to: restored, authority: .unmanagedNoDeletion)
            store = try MemoryStore(directory: restored)
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        func start() {
            let attempt = document.attempts[0]
            let operation = AnswerAttemptCoordinator(store: store,
                conversationID: conversations[key(attempt.project_id, attempt.conversation_key)]!,
                projectID: project(attempt.project_id), prompt: attempt.effectivePrompt,
                settings: document.configuration.settings, retrievalStrategy: .hybrid,
                lexicalQueryUTF8Range: attempt.lexicalQueryUTF8Range, semanticQueryUTF8Range: attempt.lexicalQueryUTF8Range,
                evidenceSourceIDs: attempt.evidence_source_ids,
                onStage: { [self] stage, _ in if kind == "stopped" && stage == .answering { coordinator?.cancel() } },
                onText: { _ in }, onComplete: { [self] result, _ in finish(result) })
            coordinator = operation
            do { _ = try operation.accept(); try operation.start() }
            catch { completion(["source_control_\(kind)_coordinator_started": false]) }
        }
        private func finish(_ result: AnswerAttemptCompletion) {
            let prefix = "source_control_" + kind + "_", restored = directory.appendingPathComponent("restored")
            func validate() -> [String: Any] {
                validateSourceControl(document: document, completion: result, directory: restored, conversations: conversations)
            }
            func invalid(_ outcome: [String: Any]) -> Bool {
                outcome["source_body_count_revalidated"] as? Bool == false
                    && outcome["complete_declared_sources_delivered"] is NSNull
                    && outcome["failure_code"] as? String == "source_control_source_body_count_invalid"
            }
            let outcome = validate(), ids = document.attempts[0].evidence_source_ids!
            var checks: [String: Bool] = [
                prefix + "ordinary_v3_counted_source_body_proof_revalidated": outcome["source_body_count_revalidated"] as? Bool == true
                    && outcome["input_proof_version"] as? Int == 3 && result.invocationStarted,
                prefix + "complete_delivery_is_independent_of_answer_status": outcome["complete_declared_sources_delivered"] as? Bool == (kind != "reduced")
                    && outcome["declared_source_count"] as? Int == ids.count
                    && outcome["declared_source_bytes"] as? Int == document.events.reduce(0, { $0 + $1.text.utf8.count }),
                prefix + "explicit_reduction_or_complete_outcome": kind == "reduced"
                    ? outcome["failure_code"] as? String == "declared_sources_not_delivered"
                        && (outcome["delivered_source_count"] as? Int).map { $0 < ids.count } == true
                    : outcome["failure_code"] is NSNull && outcome["delivered_source_count"] as? Int == ids.count,
                prefix + "terminal_capture_and_original_accounting_preserved": result.captureHealthy && result.accountingHealthy
                    && result.captureStatus == (kind == "stopped" ? .cancelled : .complete)
            ]
            do {
                guard let preparation = result.preparation,
                      let audit = try JSONSerialization.jsonObject(with: preparation.contextAudit) as? [String: Any],
                      let historical = audit["historical_sources"] as? [[String: Any]],
                      let workID = preparation.sourceSelectionWorkID,
                      let selectionBytes = try store.episodeWork(episodeID: result.identifiers.episodeID, operationID: workID)?.request.snapshot,
                      let selection = try JSONSerialization.jsonObject(with: selectionBytes) as? [String: Any],
                      let recentIDs = selection["recent_source_ids"] as? [String] else { throw Failure.invalid }
                let historicalIDs = historical.compactMap { $0["event_id"] as? String }
                if kind != "reduced" {
                    checks[prefix + "exact_declared_union_spans_recent_and_cross_conversation_history"] = recentIDs == ["synthetic-declared-0"]
                        && historicalIDs == ["synthetic-declared-1", "synthetic-declared-2"]
                        && ExactSourceIDs(recentIDs + historicalIDs) == ExactSourceIDs(ids)
                }
                let originalCharge = try store.episodeReceipt(id: result.identifiers.episodeID, clock: SystemEpisodeClock().now()).charged
                _ = validate()
                checks[prefix + "offline_integrity_does_not_change_original_charges"] = try store.episodeReceipt(id: result.identifiers.episodeID,
                    clock: SystemEpisodeClock().now()).charged == originalCharge
                var changedRoot = sourceControlFixture(baseURL: document.configuration.endpoint, reduced: kind == "reduced")
                var attempts = changedRoot["attempts"] as! [[String: Any]]
                attempts[0]["prompt"] = "Changed public synthetic current question"; changedRoot["attempts"] = attempts
                let changed = try decode(witnessFixtureBytes(changedRoot), pins: sourceControlFixturePins(changedRoot))
                checks[prefix + "full_original_question_mismatch_rejected"] = invalid(validateSourceControl(document: changed,
                    completion: result, directory: restored, conversations: conversations))
                var raw: OpaquePointer?
                guard sqlite3_open_v2(restored.appendingPathComponent("memory.sqlite3").path, &raw, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
                      let database = raw else { if let raw { sqlite3_close(raw) }; throw Failure.io }
                defer { sqlite3_close(database) }
                let invocation = try AuthorityStateKernel.rows(database,
                    "SELECT request_body,admission_json FROM invocations WHERE id=?", [.text(result.identifiers.invocationID)])
                guard invocation.count == 1, let body = invocation[0][0].bytes, let admission = invocation[0][1].bytes,
                      var admissionObject = try JSONSerialization.jsonObject(with: admission) as? [String: Any],
                      var receipt = admissionObject["receipt"] as? [String: Any] else { throw Failure.invalid }
                try AuthorityStateKernel.execute(database, "UPDATE invocations SET request_body=? WHERE id=?",
                    [.bytes(Data("{}".utf8)), .text(result.identifiers.invocationID)])
                checks[prefix + "actual_counted_body_tamper_rejected"] = invalid(validate())
                try AuthorityStateKernel.execute(database, "UPDATE invocations SET request_body=? WHERE id=?",
                    [.bytes(body), .text(result.identifiers.invocationID)])
                receipt["promptTokens"] = (receipt["promptTokens"] as? Int ?? 0) + 1; admissionObject["receipt"] = receipt
                try AuthorityStateKernel.execute(database, "UPDATE invocations SET admission_json=? WHERE id=?",
                    [.bytes(try witnessFixtureBytes(admissionObject)), .text(result.identifiers.invocationID)])
                checks[prefix + "count_receipt_tamper_rejected"] = invalid(validate())
                try AuthorityStateKernel.execute(database, "UPDATE invocations SET admission_json=? WHERE id=?",
                    [.bytes(admission), .text(result.identifiers.invocationID)])
                var alteredDate = document.events[0].source_time!.object
                alteredDate["locator"] = "/synthetic/changed-date-provenance"
                try AuthorityStateKernel.execute(database, "UPDATE events SET source_time_json=? WHERE id=?",
                    [.bytes(try witnessFixtureBytes(alteredDate)), .text(document.events[0].id)])
                checks[prefix + "original_date_provenance_tamper_rejected_even_if_omitted"] = invalid(validate())
                try AuthorityStateKernel.execute(database, "UPDATE events SET source_time_json=? WHERE id=?",
                    [.bytes(try document.events[0].source_time!.canonicalData()), .text(document.events[0].id)])
                checks[prefix + "restored_original_bytes_revalidate_again"] = validate()["source_body_count_revalidated"] as? Bool == true
            } catch { checks[prefix + "integrity_fixture_completed"] = false }
            completion(checks)
        }
    }

    private final class WitnessCheckAttempt {
        let document: Document, kind: String, directory: URL, store: MemoryStore, conversationID: String
        let completion: ([String: Bool]) -> Void
        var coordinator: AnswerAttemptCoordinator?
        init(baseURL: String, kind: String, completion: @escaping ([String: Bool]) -> Void) throws {
            self.kind = kind; self.completion = completion
            let root = witnessFixture(baseURL: baseURL, large: kind == "reduced", json: kind == "json_complete")
            document = try decode(witnessFixtureBytes(root), pins: witnessFixturePins(root))
            guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw Failure.io }
            let path = String(cString: resolved); free(resolved)
            directory = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("boros-witness-check-" + UUID().uuidString)
            let baseline = try MemoryStore(directory: directory.appendingPathComponent("baseline"))
            conversationID = try baseline.createConversation(projectID: project(document.attempts[0].project_id), title: "Synthetic witness fixture").id
            for event in document.events {
                _ = try baseline.append(conversationID: conversationID, role: event.role == "user" ? .human : .assistant,
                    text: event.text, status: event.status, turnID: "synthetic-turn:" + event.id, eventID: event.id)
            }
            let archive = directory.appendingPathComponent("archive"), restored = directory.appendingPathComponent("restored")
            _ = try BackupArchive.create(from: baseline, at: archive)
            _ = try BackupArchive.restore(from: archive, to: restored, authority: .unmanagedNoDeletion)
            store = try MemoryStore(directory: restored)
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        func start() {
            let operation = AnswerAttemptCoordinator(store: store, conversationID: conversationID,
                projectID: project(document.attempts[0].project_id), prompt: document.attempts[0].prompt,
                settings: document.configuration.settings, retrievalStrategy: .recentOnly,
                onStage: { [self] stage, _ in if kind == "stopped" && stage == .answering { coordinator?.cancel() } },
                onText: { _ in }, onComplete: { [self] result, _ in finish(result) })
            coordinator = operation
            do { _ = try operation.accept(); try operation.start() }
            catch { completion(["witness_\(kind)_coordinator_started": false]) }
        }
        private func finish(_ result: AnswerAttemptCompletion) {
            let prefix = "witness_" + kind + "_", restored = directory.appendingPathComponent("restored")
            var checks: [String: Bool] = [:]
            let validated = validateWitness(document: document, completion: result, directory: restored, conversationID: conversationID)
            checks[prefix + "actual_v3_source_body_count_revalidated"] = validated["source_body_count_revalidated"] as? Bool == true
                && validated["input_proof_version"] as? Int == 3 && result.invocationStarted
            checks[prefix + "original_pack_outcome_explicit"] = validated["complete_pack_delivered"] as? Bool == (kind != "reduced")
                && validated["declared_source_count"] as? Int == document.events.count
                && validated["declared_source_bytes"] as? Int == document.events.reduce(0, { $0 + $1.text.utf8.count })
            checks[prefix + "fixed_failure_code"] = kind == "reduced" ? validated["failure_code"] as? String == "witness_pack_not_delivered"
                : validated["failure_code"] is NSNull
            checks[prefix + "post_terminal_inspection_timed"] = (validated["validation_milliseconds"] as? Double).map { $0.isFinite && $0 >= 0 } == true
            checks[prefix + "terminal_capture_preserved"] = result.captureHealthy && result.accountingHealthy
                && (kind == "stopped" ? result.captureStatus == .cancelled : result.captureStatus == .complete)
            do {
                let originalCharge = try store.episodeReceipt(id: result.identifiers.episodeID, clock: SystemEpisodeClock().now()).charged
                if kind == "json_complete" {
                    guard let original = try store.invocation(id: result.identifiers.invocationID),
                          let request = try JSONSerialization.jsonObject(with: original.requestBody) as? [String: Any] else { throw Failure.invalid }
                    checks[prefix + "actual_frozen_request_mode"] = (request["response_format"] as? [String: String]) == ["type": "json_object"]
                    let savedArchive = directory.appendingPathComponent("captured-archive")
                    let savedRestore = directory.appendingPathComponent("captured-restore")
                    _ = try BackupArchive.create(from: store, at: savedArchive)
                    _ = try BackupArchive.restore(from: savedArchive, to: savedRestore, authority: .unmanagedNoDeletion)
                    let reopened = try MemoryStore(directory: savedRestore)
                    let restoredInvocation = try reopened.invocation(id: result.identifiers.invocationID)
                    let restoredCharge = try reopened.episodeReceipt(id: result.identifiers.episodeID, clock: SystemEpisodeClock().now()).charged
                    checks[prefix + "captured_receipt_archive_restore_preserved"] = restoredInvocation?.requestBody == original.requestBody
                        && restoredInvocation?.admissionJSON == original.admissionJSON
                        && restoredInvocation?.finalStatus == original.finalStatus
                        && restoredCharge == originalCharge
                }
                _ = validateWitness(document: document, completion: result, directory: restored, conversationID: conversationID)
                checks[prefix + "verification_does_not_change_original_debits"] = try store.episodeReceipt(id: result.identifiers.episodeID,
                    clock: SystemEpisodeClock().now()).charged == originalCharge
                var changedRoot = witnessFixture(baseURL: document.configuration.endpoint, large: kind == "reduced", json: kind == "json_complete")
                var configuration = changedRoot["configuration"] as! [String: Any]; configuration["system"] = "Changed public synthetic host."
                changedRoot["configuration"] = configuration
                let changed = try decode(witnessFixtureBytes(changedRoot), pins: witnessFixturePins(changedRoot))
                let host = validateWitness(document: changed, completion: result, directory: restored, conversationID: conversationID)
                checks[prefix + "host_mismatch_cannot_claim_proof"] = host["source_body_count_revalidated"] as? Bool == false
                    && host["complete_pack_delivered"] is NSNull
                var raw: OpaquePointer?
                guard sqlite3_open_v2(restored.appendingPathComponent("memory.sqlite3").path, &raw, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
                      let database = raw else { if let raw { sqlite3_close(raw) }; throw Failure.io }
                defer { sqlite3_close(database) }
                let invocation = try AuthorityStateKernel.rows(database,
                    "SELECT request_body,admission_json FROM invocations WHERE id=?", [.text(result.identifiers.invocationID)])
                guard invocation.count == 1, let body = invocation[0][0].bytes, let admission = invocation[0][1].bytes,
                      var audit = try JSONSerialization.jsonObject(with: admission) as? [String: Any] else { throw Failure.invalid }
                try AuthorityStateKernel.execute(database, "UPDATE invocations SET request_body=? WHERE id=?",
                    [.bytes(Data("{}".utf8)), .text(result.identifiers.invocationID)])
                let wrongBody = validateWitness(document: document, completion: result, directory: restored, conversationID: conversationID)
                checks[prefix + "actual_body_mismatch_rejected"] = wrongBody["source_body_count_revalidated"] as? Bool == false
                    && wrongBody["complete_pack_delivered"] is NSNull
                try AuthorityStateKernel.execute(database, "UPDATE invocations SET request_body=? WHERE id=?",
                    [.bytes(body), .text(result.identifiers.invocationID)])
                audit["version"] = 2; audit.removeValue(forKey: "inputProofWorkID"); audit.removeValue(forKey: "inputProofSHA256")
                try AuthorityStateKernel.execute(database, "UPDATE invocations SET admission_json=? WHERE id=?",
                    [.bytes(try witnessFixtureBytes(audit)), .text(result.identifiers.invocationID)])
                let oldProof = validateWitness(document: document, completion: result, directory: restored, conversationID: conversationID)
                checks[prefix + "version_two_cannot_claim_complete_proof"] = oldProof["source_body_count_revalidated"] as? Bool == false
                    && oldProof["complete_pack_delivered"] is NSNull
                try AuthorityStateKernel.execute(database, "UPDATE invocations SET admission_json=? WHERE id=?",
                    [.bytes(admission), .text(result.identifiers.invocationID)])
                // First source is deliberately geometrically omitted in the
                // reduced fixture. All-original validation must still fail.
                try AuthorityStateKernel.execute(database, "UPDATE events SET status='partial' WHERE id=?", [.text(document.events[0].id)])
                let tampered = validateWitness(document: document, completion: result, directory: restored, conversationID: conversationID)
                checks[prefix + "entire_original_union_tamper_rejected"] = tampered["source_body_count_revalidated"] as? Bool == false
                    && tampered["complete_pack_delivered"] is NSNull && tampered["failure_code"] as? String == "witness_source_body_count_invalid"
                try AuthorityStateKernel.execute(database, "UPDATE events SET status='complete' WHERE id=?", [.text(document.events[0].id)])
                try AuthorityStateKernel.execute(database, "DELETE FROM invocations WHERE id=?", [.text(result.identifiers.invocationID)])
                let missing = validateWitness(document: document, completion: result, directory: restored, conversationID: conversationID)
                checks[prefix + "missing_invocation_cannot_claim_proof"] = missing["source_body_count_revalidated"] as? Bool == false
                    && missing["complete_pack_delivered"] is NSNull
                let unknown = witnessOutcome(events: document.events, failure: "witness_outcome_unavailable")
                checks[prefix + "unavailable_preserves_declared_counts"] = unknown["declared_source_count"] as? Int == document.events.count
                    && unknown["declared_source_bytes"] as? Int == document.events.reduce(0, { $0 + $1.text.utf8.count })
                    && unknown["complete_pack_delivered"] is NSNull && unknown["source_body_count_revalidated"] is NSNull
                    && unknown["validation_milliseconds"] is NSNull
            } catch { checks[prefix + "integrity_fixture_completed"] = false }
            completion(checks)
        }
    }
}
