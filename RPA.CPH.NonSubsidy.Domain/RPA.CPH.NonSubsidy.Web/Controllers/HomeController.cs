using PagedList;
using RPA.CPH.NonSubsidy.Domain.Classes.Audit;
using RPA.CPH.NonSubsidy.Domain.Classes.CPH;
using RPA.CPH.NonSubsidy.Domain.Interfaces;
using RPA.CPH.NonSubsidy.Domain.UnitOfWork;
using RPA.CPH.NonSubsidy.Web.Models;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Web;
using System.Web.Mvc;

namespace RPA.CPH.NonSubsidy.Web.Controllers
{
    [Authorize(Roles = "CPH Non Subsidy: Basic Access")]
    public class HomeController : Controller
    {
        IUnitOfWork uow;
        IUser user;

        public HomeController()
        {
            this.uow = new UnitOfWork();
            this.user = new User();
        }

        public HomeController(IUnitOfWork uow, IUser user)
        {
            this.uow = uow;
            this.user = user;
        }

        public ActionResult Index(string searchString = null, int page = 1, int pageSize = 20)
        {
            List<Customer> customers;

            if(!string.IsNullOrEmpty(searchString))
            {
                customers = uow.CustomerRepository.FindBy(x => x.SBI.ToString() == searchString.Trim()).OrderByDescending(x => x.Audit.LastUpdated).ThenBy(x => x.SBI).ToList();
            }
            else
            {
                customers = uow.CustomerRepository.GetAll().OrderByDescending(x => x.Audit.LastUpdated).ThenBy(x => x.SBI).ToList();
                ViewBag.SearchString = searchString;
            }

            PagedList<Customer> model = new PagedList<Customer>(customers, page, pageSize);

            return View(model);
        }

        public ActionResult Customer(int? customerId = null)
        {
            Customer customer;

            if(customerId != null)
            {
                customer = uow.CustomerRepository.GetById(customerId);
                ViewBag.IsUpdate = true;
            }
            else
            {
                customer = new Customer(new Address(), new Land(), new Case(), new Audit());
                ViewBag.IsUpdate = false;
            }            

            return View(customer);
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public ActionResult Customer(Customer customer, Case _case, Address address, Land land, List<LandParcel> LandParcels, Audit audit, bool IsUpdate, string submit)
        {
            if(submit == "delete")
            {
                uow.CustomerRepository.Delete(customer.CustomerId);
                uow.Commit();

                return RedirectToAction("Index");
            }

            if(LandParcels == null)
            {
                LandParcels = new List<LandParcel>();
            }
            else
            {
                LandParcels = LandParcels.Where(x => (x.LandParcelId == 0 && x.GridReference != null) || (x.LandParcelId > 0)).ToList();
            }

            customer.Case = _case;
            customer.Addresses = new List<Address> { address };
            customer.Land = new List<Land> { land };
            customer.Land.FirstOrDefault().LandParcels = LandParcels;
            customer.Audit = audit;

            ViewBag.IsUpdate = IsUpdate;

            if (ModelState.IsValid)
            {
                if(LandParcels.Where(x=>x.Active).Count() > 0 && LandParcels.Where(x=>x.IsPlaceOfBusiness && x.Active).ToList().Count != 1)
                {
                    if (LandParcels.Where(x => x.IsPlaceOfBusiness && x.Active).ToList().Count == 0)
                    {
                        ModelState.AddModelError("POB", "One POB is required.");
                    }
                    else
                    {
                        ModelState.AddModelError("POB", "One POB is allowed.");
                    }

                    return View(customer);
                }

                if(LandParcels.Where(x => x.Active).GroupBy(x=>x.GridReference).Where(p=>p.Count()>1).Count() > 0)
                {
                    ModelState.AddModelError("GridReference", "Duplicate Grid Reference identified.");

                    return View(customer);
                }                

                customer.Audit.Update(user.Name);

                if (IsUpdate)
                {
                    foreach (LandParcel landParcel in customer.Land.FirstOrDefault().LandParcels)
                    {
                        if (landParcel.LandParcelId == 0)
                        {
                            if (landParcel.Active)
                            {
                                uow.LandParcelRepository.Create(landParcel);
                            }
                        }
                        else
                        {
                            uow.LandParcelRepository.Update(landParcel);
                        }
                    }

                    uow.CustomerRepository.Update(customer);
                    uow.CaseRepository.Update(_case);
                    uow.AddressRepository.Update(address);
                    uow.LandRepository.Update(land);
                }
                else
                {
                    customer.Land.FirstOrDefault().LandParcels = LandParcels.Where(x => x.Active).ToList();                    

                    uow.CustomerRepository.Create(customer);
                }

                uow.Commit();

                return RedirectToAction("Index");
            }

            return View(customer);
        }

        public PartialViewResult _LandParcel(LandParcel landParcel)
        {
            return PartialView("_LandParcel", landParcel);
        }

        public PartialViewResult _NewLandParcel(int landId)
        {
            LandParcel landParcel = new LandParcel(landId);

            return PartialView("_LandParcel", landParcel);
        }

        public ActionResult Extract()
        {
            List<LandParcel> landParcels = uow.LandParcelRepository.FindBy(x => x.Active).OrderBy(x => x.Land.Customer.SBI).ThenBy(x => x.GridReference).ToList();

            StringBuilder sb = new StringBuilder();

            sb.AppendLine("SBI,BusinessName,BusinessAddress,CPH,PlaceOfBusinessReferenceNumber,AdditionalGridReferences,CRMCaseReferenceNumber,UpdatedBy,Updated");

            foreach(LandParcel landParcel in landParcels)
            {
                sb.AppendLine(landParcel.ToCSV());
            }

            DateTime date = DateTime.Now;

            return File(new UTF8Encoding().GetBytes(sb.ToString()), "text/csv", string.Format("Non_Subsidy_CPHs_{0}{1}{2}{3}{4}.csv", date.Day, date.Month, date.Year, date.Hour, date.Minute));
        }
    }
}