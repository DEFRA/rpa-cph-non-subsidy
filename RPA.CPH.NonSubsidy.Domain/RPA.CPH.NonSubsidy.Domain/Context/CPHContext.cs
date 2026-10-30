using Microsoft.EntityFrameworkCore;
using System.ComponentModel.DataAnnotations;
using RPA.CPH.NonSubsidy.Domain.Classes.Audit;
using RPA.CPH.NonSubsidy.Domain.Classes.CPH;

namespace RPA.CPH.NonSubsidy.Domain.Context;

public class CPHContext : DbContext
{
    public CPHContext(DbContextOptions<CPHContext> options) : base(options)
    {
    }

    public DbSet<Customer> Customers { get; set; }
    public DbSet<Address> Addresses { get; set; }
    public DbSet<Land> Land { get; set; }
    public DbSet<LandParcel> LandParcels { get; set; }
    public DbSet<Case> Case { get; set; }
    public DbSet<Audit> Audit { get; set; }

    public override int SaveChanges(bool acceptAllChangesOnSuccess)
    {
        ValidatePendingEntities();
        return base.SaveChanges(acceptAllChangesOnSuccess);
    }

    public override Task<int> SaveChangesAsync(bool acceptAllChangesOnSuccess, CancellationToken cancellationToken = default)
    {
        ValidatePendingEntities();
        return base.SaveChangesAsync(acceptAllChangesOnSuccess, cancellationToken);
    }

    private void ValidatePendingEntities()
    {
        // EF6 validated annotations on save; EF Core does not do so automatically.
        foreach (var entry in ChangeTracker.Entries()
            .Where(x => x.State is EntityState.Added or EntityState.Modified))
            Validator.ValidateObject(entry.Entity, new ValidationContext(entry.Entity), validateAllProperties: true);
    }

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<Customer>(entity =>
        {
            entity.ToTable("Customers", "CPH");
            entity.HasKey(x => x.CustomerId).HasName("PK_CPH.Customers");
            entity.Property(x => x.CustomerId).ValueGeneratedOnAdd();
            entity.HasMany(x => x.Addresses).WithOne(x => x.Customer)
                .HasForeignKey(x => x.CustomerId).IsRequired().OnDelete(DeleteBehavior.Cascade)
                .HasConstraintName("FK_CPH.Addresses_CPH.Customers_CustomerId");
            entity.HasMany(x => x.Land).WithOne(x => x.Customer)
                .HasForeignKey(x => x.CustomerId).IsRequired().OnDelete(DeleteBehavior.Cascade)
                .HasConstraintName("FK_CPH.Land_CPH.Customers_CustomerId");
            entity.HasOne(x => x.Case).WithOne(x => x.Customer)
                .HasForeignKey<Case>(x => x.CustomerId).IsRequired().OnDelete(DeleteBehavior.Cascade)
                .HasConstraintName("FK_CPH.Cases_CPH.Customers_CustomerId");
            entity.HasOne(x => x.Audit).WithOne(x => x.Customer)
                .HasForeignKey<Audit>(x => x.CustomerId).IsRequired().OnDelete(DeleteBehavior.Cascade)
                .HasConstraintName("FK_Audit.Audit_CPH.Customers_CustomerId");
            entity.Navigation(x => x.Case).IsRequired();
            entity.Navigation(x => x.Audit).IsRequired();
        });
        modelBuilder.Entity<Address>(entity =>
        {
            entity.ToTable("Addresses", "CPH");
            entity.HasKey(x => x.AddressId).HasName("PK_CPH.Addresses");
            entity.HasIndex(x => x.CustomerId).HasDatabaseName("IX_CustomerId");
            entity.Property(x => x.AddressId).ValueGeneratedOnAdd();
            entity.Ignore(x => x.FullAddress);
        });
        modelBuilder.Entity<Land>(entity =>
        {
            entity.ToTable("Land", "CPH");
            entity.HasKey(x => x.LandId).HasName("PK_CPH.Land");
            entity.HasIndex(x => x.CustomerId).HasDatabaseName("IX_CustomerId");
            entity.Property(x => x.LandId).ValueGeneratedOnAdd();
            entity.HasMany(x => x.LandParcels).WithOne(x => x.Land)
                .HasForeignKey(x => x.LandId).IsRequired().OnDelete(DeleteBehavior.Cascade)
                .HasConstraintName("FK_CPH.LandParcels_CPH.Land_LandId");
            entity.Ignore(x => x.CPH);
            entity.Ignore(x => x.PlaceOfBusinessReference);
            entity.Ignore(x => x.LandParcelDetails);
        });
        modelBuilder.Entity<LandParcel>(entity =>
        {
            entity.ToTable("LandParcels", "CPH");
            entity.HasKey(x => x.LandParcelId).HasName("PK_CPH.LandParcels");
            entity.HasIndex(x => x.LandId).HasDatabaseName("IX_LandId");
            entity.Property(x => x.LandParcelId).ValueGeneratedOnAdd();
            // Owner DDL defaults to 0; always send the CLR value (constructor defaults to true).
            entity.Property(x => x.Active).HasDefaultValue(false).ValueGeneratedNever();
            entity.Ignore(x => x.IsPlaceOfBusiness);
        });
        modelBuilder.Entity<Case>(entity =>
        {
            entity.ToTable("Cases", "CPH");
            entity.HasKey(x => x.CustomerId).HasName("PK_CPH.Cases");
            entity.HasIndex(x => x.CustomerId).HasDatabaseName("IX_CustomerId");
            entity.Property(x => x.CustomerId).ValueGeneratedNever();
        });
        modelBuilder.Entity<Audit>(entity =>
        {
            entity.ToTable("Audit", "Audit");
            entity.HasKey(x => x.CustomerId).HasName("PK_Audit.Audit");
            entity.HasIndex(x => x.CustomerId).HasDatabaseName("IX_CustomerId");
            entity.Property(x => x.CustomerId).ValueGeneratedNever();
            // EF6's original column is datetime, not EF Core's default datetime2.
            entity.Property(x => x.LastUpdated).HasColumnType("datetime");
            entity.Ignore(x => x.LastUpdatedDetails);
        });
    }
}
