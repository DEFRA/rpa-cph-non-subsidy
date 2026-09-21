using RPA.CPH.NonSubsidy.Domain.Classes.Audit;
using RPA.CPH.NonSubsidy.Domain.Classes.CPH;
using System;
using System.Collections.Generic;
using System.Data.Entity;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace RPA.CPH.NonSubsidy.Domain.Context
{
    public class CPHContext : DbContext
    {
        public DbSet<Customer> Customers { get; set; }

        public DbSet<Address> Addresses { get; set; }
        
        public DbSet<Land> Land { get; set; }

        public DbSet<LandParcel> LandParcels { get; set; }

        public DbSet<Case> Case { get; set; }

        public DbSet<Audit> Audit { get; set; }

        protected override void OnModelCreating(DbModelBuilder modelBuilder)
        {
            modelBuilder.Entity<Customer>()
                .HasRequired(x => x.Audit)
                .WithRequiredPrincipal(x => x.Customer)
                .WillCascadeOnDelete(true);

            modelBuilder.Entity<Customer>()
                .HasRequired(x => x.Case)
                .WithRequiredPrincipal(x => x.Customer)
                .WillCascadeOnDelete(true);            
        }
    }
}
