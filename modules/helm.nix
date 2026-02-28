# helm defines kubenix module with options for using helm charts
# with kubenix
{ config, lib, pkgs, helm, ... }:
with lib; let
  cfg = config.kubernetes.helm;

  globalConfig = config;

  recursiveAttrs = mkOptionType {
    name = "recursive-attrs";
    description = "recursive attribute set";
    check = isAttrs;
    merge = _loc: foldl' (res: def: recursiveUpdate res def.value) { };
  };

  parseApiVersion = apiVersion:
    let
      splitted = splitString "/" apiVersion;
    in
    {
      group =
        if length splitted == 1
        then "core"
        else head splitted;
      version = last splitted;
    };

  matchesResource = object: matcher:
    let
      objectApiVersion = object.apiVersion or "";
      objectKind = object.kind or "";
      objectName = object.metadata.name or "";
      objectNamespace = object.metadata.namespace or "";
    in
    (matcher.apiVersion == null || matcher.apiVersion == objectApiVersion)
    && (matcher.kind == null || matcher.kind == objectKind)
    && (matcher.name == null || matcher.name == objectName)
    && (matcher.namespace == null || matcher.namespace == objectNamespace);

  matchedResourcePatches = object: resourceOverrides:
    map (override: override.patch) (filter (override: matchesResource object override.match) resourceOverrides);
in
{
  imports = [ ./k8s.nix ];

  options.kubernetes.helm = {
    releases = mkOption {
      description = "Attribute set of helm releases";
      type = types.attrsOf (types.submodule ({ config, name, ... }: {
        options = {
          name = mkOption {
            description = "Helm release name";
            type = types.str;
            default = name;
          };

          chart = mkOption {
            description = "Helm chart to use";
            type = types.package;
          };

          namespace = mkOption {
            description = "Namespace to install helm chart to";
            type = types.nullOr types.str;
            default = null;
          };

          values = mkOption {
            description = "Values to pass to chart";
            type = recursiveAttrs;
            default = { };
          };

          kubeVersion = mkOption {
            description = "Kubernetes version to build chart for";
            type = types.str;
            default = globalConfig.kubernetes.version;
          };

          overrides = mkOption {
            description = "Overrides to apply to all chart resources";
            type = types.listOf types.unspecified;
            default = [ ];
          };

          resourceOverrides = mkOption {
            description = ''
              Overrides to apply only to matching chart resources.
              Matching fields are optional; omitted fields match any value.
            '';
            type = types.listOf (types.submodule {
              options = {
                match = {
                  apiVersion = mkOption {
                    description = "Match object apiVersion";
                    type = types.nullOr types.str;
                    default = null;
                  };
                  kind = mkOption {
                    description = "Match object kind";
                    type = types.nullOr types.str;
                    default = null;
                  };
                  name = mkOption {
                    description = "Match object metadata.name";
                    type = types.nullOr types.str;
                    default = null;
                  };
                  namespace = mkOption {
                    description = "Match object metadata.namespace";
                    type = types.nullOr types.str;
                    default = null;
                  };
                };

                patch = mkOption {
                  description = "Patch merged into each matched object";
                  type = types.unspecified;
                  default = { };
                };
              };
            });
            default = [ ];
          };

          overrideNamespace = mkOption {
            description = "Whether to apply namespace override";
            type = types.bool;
            default = true;
          };

          includeCRDs = mkOption {
            description = ''
              Whether to include CRDs.

              Warning: Always including CRDs here is dangerous and can break CRs in your cluster as CRDs may be updated unintentionally.
              An interactive `helm install` NEVER updates CRDs, only installs them when they are not existing.
              See https://github.com/helm/community/blob/aa8e13054d91ee69857b13149a9652be09133a61/hips/hip-0011.md

              Only set this to true if you know what you are doing and are manually checking the included CRDs for breaking changes whenever updating the Helm chart.
            '';
            type = types.bool;
            default = false;
          };

          noHooks = mkOption {
            description = ''
              Wether to include Helm hooks.

              Without this all hooks run immediately on apply since we are bypassing the Helm CLI.
              However, some charts only have minor validation hooks (e.g., upgrade version skew validation) and are safe to ignore.
            '';
            type = types.bool;
            default = false;
          };

          apiVersions = mkOption {
            description = ''
              Inform Helm about which CRDs are available in the cluster (`--api-versions` option).
              This is useful for charts which contain `.Capabilities.APIVersions.Has` checks.
              If you use `kubernetes.customTypes` to make kubenix aware of CRDs, it will include those as well by default.
            '';
            type = types.listOf types.str;
            default = builtins.concatMap
              (customType:
                [
                  "${customType.group}/${customType.version}"
                  "${customType.group}/${customType.version}/${customType.kind}"
                ])
              (builtins.attrValues globalConfig.kubernetes.customTypes);
          };

          objects = mkOption {
            description = "Generated kubernetes objects";
            type = types.listOf types.attrs;
            default = [ ];
          };
        };

        config.overrides = mkIf (config.overrideNamespace && config.namespace != null) [{
          metadata.namespace = config.namespace;
        }];

        config.objects = importJSON (helm.chart2json {
          inherit (config) chart name namespace values kubeVersion includeCRDs noHooks apiVersions;
        });
      }));
      default = { };
    };
  };

  config = {
    # expose helm helper methods as module argument
    _module.args.helm = import ../lib/helm { inherit pkgs; };

    kubernetes.api.resources = mkMerge (flatten (mapAttrsToList
      (_: release: map
        (object:
          let
            apiVersion = parseApiVersion object.apiVersion;
            inherit (object.metadata) name;
          in
          {
            "${apiVersion.group}"."${apiVersion.version}".${object.kind}."${name}" = mkMerge ([
              object
            ]
            ++ matchedResourcePatches object release.resourceOverrides
            ++ release.overrides);
          })
        release.objects
      )
      cfg.releases));
  };
}
