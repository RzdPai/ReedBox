import { Profile } from '../../model/Profile';

/** A persistent row owns its display snapshot; identity never depends on selection or latency. */
@ObservedV2
export class ProfileRowModel {
  readonly profileId: string;
  @Trace profile: Profile = new Profile();
  @Trace selected: boolean = false;
  @Trace running: boolean = false;
  @Trace showAddress: boolean = false;
  @Trace canSelect: boolean = true;
  private sourceProfile: Profile;
  private displaySignature: string = '';

  constructor(profile: Profile) {
    this.profileId = profile.id;
    this.sourceProfile = profile;
    this.updateProfile(profile);
  }

  currentProfile(): Profile {
    return this.sourceProfile;
  }

  updateProfile(profile: Profile): void {
    const signature: string = JSON.stringify([
      profile.name, profile.server, `${profile.serverPort}`, profile.type, `${profile.pinned}`,
      `${profile.rx}`, `${profile.tx}`, `${profile.latencyMs}`, `${profile.latencyTestedAt}`
    ]);
    const replace: boolean = this.sourceProfile !== profile || this.displaySignature !== signature;
    this.sourceProfile = profile;
    if (replace) {
      // Profile is plain data. Replace the traced snapshot when an in-place business edit changes the row.
      this.profile = JSON.parse(JSON.stringify(profile)) as Profile;
      this.displaySignature = signature;
    }
  }

  updateState(selectedId: string, runningId: string, showAddress: boolean, canSelect: boolean): void {
    this.selected = this.profileId === selectedId;
    this.running = this.profileId === runningId;
    this.showAddress = showAddress;
    this.canSelect = canSelect;
  }
}

/** Keep this IDataSource instance for the page lifetime; notify only structural changes. */
export class ProfileRowSource implements IDataSource {
  private rows: Array<ProfileRowModel> = [];
  private rowsById: Map<string, ProfileRowModel> = new Map<string, ProfileRowModel>();
  private listeners: Array<DataChangeListener> = [];

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): ProfileRowModel {
    return this.rows[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  reset(profiles: Array<Profile>, selectedId: string, runningId: string,
    showAddress: boolean, canSelect: boolean): boolean {
    const next: Array<ProfileRowModel> = [];
    const nextById: Map<string, ProfileRowModel> = new Map<string, ProfileRowModel>();
    let structureChanged: boolean = profiles.length !== this.rows.length;
    for (let index: number = 0; index < profiles.length; index++) {
      const profile: Profile = profiles[index];
      let row: ProfileRowModel | undefined = this.rowsById.get(profile.id);
      if (row === undefined) {
        row = new ProfileRowModel(profile);
      } else {
        row.updateProfile(profile);
      }
      row.updateState(selectedId, runningId, showAddress, canSelect);
      if (index >= this.rows.length || this.rows[index].profileId !== profile.id) {
        structureChanged = true;
      }
      next.push(row);
      nextById.set(profile.id, row);
    }
    this.rows = next;
    this.rowsById = nextById;
    if (structureChanged) {
      const copy: Array<DataChangeListener> = this.listeners.slice();
      for (const listener of copy) {
        listener.onDataReloaded();
      }
    }
    return structureChanged;
  }

  updateStates(selectedId: string, runningId: string, showAddress: boolean, canSelect: boolean): void {
    for (const row of this.rows) {
      row.updateState(selectedId, runningId, showAddress, canSelect);
    }
  }

  /** 行模型数组（ForEach 拖动排序用；LazyForEach 走 getData） */
  models(): Array<ProfileRowModel> {
    return this.rows;
  }

  profiles(): Array<Profile> {
    const profiles: Array<Profile> = [];
    for (const row of this.rows) {
      profiles.push(row.currentProfile());
    }
    return profiles;
  }
}
